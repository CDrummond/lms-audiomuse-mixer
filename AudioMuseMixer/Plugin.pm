package Plugins::AudioMuseMixer::Plugin;

#
# LMS AudioMuse Mixer
#
# (c) 2026 Craig Drummond
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Copy;
use File::Slurp;
use File::Spec;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

use Plugins::AudioMuseMixer::API;
use Plugins::AudioMuseMixer::Settings;
use Plugins::AudioMuseMixer::ProtocolHandler;

use constant API_SIMILAR_TRACKS          => 0;
use constant API_SEM_GROVE               => 1;
use constant API_HYPERBOLIC              => 2;
use constant NUM_CLI_MIX_SEED_TRACKS     => 10;
use constant MIN_CLI_MIX_SEED_TRACKS     => 7;
use constant NUM_CLI_SEEDS_TO_ADD        => 4;
use constant NUM_CLI_SEEDS_TO_ADD_FEW    => 2;
use constant NUM_CLI_MIX_RESP_TRACKS_FEW => 15; # Number of tracks in a mix if few seeds
use constant NUM_CLI_MIX_RESP_TRACKS     => 30; # Number of tracks in a mix

# Defaults
use constant DEF_NO_REPEAT_ARTIST        => 10;
use constant DEF_NO_REPEAT_ALBUM         => 20;
use constant DEF_MIN_DURATION            => 90;
use constant DEF_MAX_DURATION            => 600;
use constant DEF_NUM_DSTM_RESP_TRACKS    => 10;
use constant DEF_NUM_SEED_TRACKS         => 1;
use constant DEF_MAX_PREVIOUS_TRACKS     => 100;
use constant DEF_API                     => API_HYPERBOLIC;

my %XMAS_GENRES = map { $_ => 1 } ('Christmas', 'Xmas');


my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.audiomusemixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.audiomusemixer');
my $serverprefs = preferences('server');
my $initialized = 0;
my $genreGroups = [];
my $genreGroupsTs = 0;
my $useTrackGenreTs = 0;

my %excludeArtists = ();
my $excludeArtistsTs = 0;

my %excludeAlbums = ();
my $excludeAlbumsTs = 0;

sub shutdownPlugin {
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres    => 0,
        filter_xmas      => 1,
        url              => 'http://localhost:8000',
        token            => undef,
        server_name      => '',
        api              => DEF_API,
        min_duration     => DEF_MIN_DURATION,
        max_duration     => DEF_MAX_DURATION,
        no_repeat_artist => DEF_NO_REPEAT_ARTIST,
        no_repeat_album  => DEF_NO_REPEAT_ALBUM,
        no_repeat_track  => DEF_MAX_PREVIOUS_TRACKS,
        use_track_genre  => 0,
        dstm_tracks      => DEF_NUM_DSTM_RESP_TRACKS,
        num_seed_tracks  => DEF_NUM_SEED_TRACKS,
        seed_strict_order => 0,
        match_all_genres => 0,
        exclude_artists  => '',
        exclude_albums   => ''
    });

    if ( main::WEBUI ) {
        Plugins::AudioMuseMixer::Settings->new;
    }

    #                                                            |requires Client
    #                                                            |  |is a Query
    #                                                            |  |  |has Tags
    #                                                            |  |  |  |Function to call
    #                                                            C  Q  T  F
    Slim::Control::Request::addDispatch(['audiomusemixer', '_cmd'], [0, 0, 1, \&_cliCommand]);

    Slim::Player::ProtocolHandlers->registerHandler(
        audiomusemixer => 'Plugins::AudioMuseMixer::ProtocolHandler'
    );

    if ( !main::SCANNER ) {
        Slim::Control::Request::addDispatch(['scanner', 'notify', '_msg'], [0, 0, 0, \&_notifyFromScanner]);
    }

    $initialized = 1;
    _initGenreGroups();
    _initExcludeArtists();
    _initExcludeAlbums();
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('AUDIOMUSEMIXER_DSTM', sub {
            my ($client, $cb) = @_;
            main::DEBUGLOG && $log->debug("AudioMuseMix DSTM mix");
            my $seeds = _getSeedTracksFromQueue($client);
            if ($seeds && ref $seeds && scalar @$seeds) {
                _generateMix(sub {
                    my $tracks = shift;
                    my $count = scalar @$tracks;
                    if ($count>0) {
                        $cb->($client, $tracks);
                    } else {
                        _mixFailed($client, $cb);
                    }
                },
                int($prefs->get('dstm_tracks') || DEF_NUM_DSTM_RESP_TRACKS), $seeds, 1,
                _getPreviousTracks($client, int($prefs->get('no_repeat_track') || DEF_MAX_PREVIOUS_TRACKS)),);
            } else {
                _mixFailed($client, $cb);
            }
        });
    }
}

sub _cliCommand {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotCommand([['audiomusemixer']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');

    if ($request->paramUndefinedOrNotOneOf($cmd, ['mix']) ) {
        $request->setStatusBadParams();
        return;
    }
    _cliMix($request);
    return;
}

sub _cliResponse {
    my ($tracks, $request, $seedTracks) = @_;
    my $count = scalar @$tracks;
    main::DEBUGLOG && $log->debug("CLI num tracks:" . $count);
    if ($count>0) {
        my $tags     = $request->getParam('tags') || 'al';
        my $menu     = $request->getParam('menu');
        my $menuMode = defined $menu;
        my $loopname = $menuMode ? 'item_loop' : 'titles_loop';
        my $chunkCount = 0;
        my $useContextMenu = $request->getParam('useContextMenu');
        my @ids = ();

        foreach my $track (@$tracks) {
            push @ids, $track->id;
        }

        Slim::Player::Playlist::fischer_yates_shuffle($seedTracks);
        my $numSeedsToAdd = scalar(@$tracks)>NUM_CLI_MIX_RESP_TRACKS_FEW ? NUM_CLI_SEEDS_TO_ADD : NUM_CLI_SEEDS_TO_ADD_FEW;
        if (scalar(@$seedTracks)>$numSeedsToAdd) {
            @$seedTracks = splice(@$seedTracks, 0, $numSeedsToAdd);
        }
        foreach my $track (@$seedTracks) {
            push @ids, $track->id;
        }
        Slim::Player::Playlist::fischer_yates_shuffle(\@ids);

        if ($menuMode) {
            my $idList = join( ",", @ids );
            my $base = {
                actions => {
                    go => {
                        cmd => ['trackinfo', 'items'],
                        params => {
                            menu => 'nowhere',
                            useContextMenu => '1',
                        },
                        itemsParams => 'params',
                    },
                    play => {
                        cmd => ['playlistcontrol'],
                        params => {
                            cmd  => 'load',
                            menu => 'nowhere',
                        },
                        nextWindow => 'nowPlaying',
                        itemsParams => 'params',
                    },
                    add =>  {
                        cmd => ['playlistcontrol'],
                        params => {
                            cmd  => 'add',
                            menu => 'nowhere',
                        },
                        itemsParams => 'params',
                    },
                    'add-hold' =>  {
                        cmd => ['playlistcontrol'],
                        params => {
                            cmd  => 'insert',
                            menu => 'nowhere',
                        },
                        itemsParams => 'params',
                    },
                },
            };

            if ($useContextMenu) {
                # "+ is more"
                $base->{'actions'}{'more'} = $base->{'actions'}{'go'};
                # "go is play"
                $base->{'actions'}{'go'} = $base->{'actions'}{'play'};
            }
            $request->addResult('base', $base);
            $request->addResult('offset', 0);

            my $thisWindow = {
                'windowStyle' => 'icon_list',
                'text'       => $request->string('BLISSMIXER_MIX'),
            };
            $request->addResult('window', $thisWindow);

            # add an item for "play this mix"
            $request->addResultLoop($loopname, $chunkCount, 'nextWindow', 'nowPlaying');
            $request->addResultLoop($loopname, $chunkCount, 'text', $request->string('BLISSMIXER_PLAYTHISMIX'));
            $request->addResultLoop($loopname, $chunkCount, 'icon-id', '/html/images/playall.png');
            my $actions = {
                'go' => {
                    'cmd' => ['playlistcontrol', 'cmd:load', 'menu:nowhere', 'track_id:' . $idList],
                },
                'play' => {
                    'cmd' => ['playlistcontrol', 'cmd:load', 'menu:nowhere', 'track_id:' . $idList],
                },
                'add' => {
                    'cmd' => ['playlistcontrol', 'cmd:add', 'menu:nowhere', 'track_id:' . $idList],
                },
                'add-hold' => {
                    'cmd' => ['playlistcontrol', 'cmd:insert', 'menu:nowhere', 'track_id:' . $idList],
                },
            };
            $request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
            $chunkCount++;
        }

        foreach my $trackObj (@$tracks) {
            if ($menuMode) {
                Slim::Control::Queries::_addJiveSong($request, $loopname, $chunkCount, $chunkCount, $trackObj);
            } else {
                Slim::Control::Queries::_addSong($request, $loopname, $chunkCount, $trackObj, $tags);
            }
            $chunkCount++;
        }
        main::DEBUGLOG && $log->debug("Num tracks to use:" . ($chunkCount - 1)); # Remove 'Play this mix' from count
        $request->addResult('count', $chunkCount);
    }
    $request->setStatusDone();
}

sub _cliMix {
    my $request = shift;
    my $origReqCount = $request->getParam('count') || 0;
    main::DEBUGLOG && $log->debug("AudioMuseMix CLI mix");

    my @seedsToUse = ();
    if ($request->getParam('track_id')) {
        my ($trackObj) = Slim::Schema->find('Track', $request->getParam('track_id'));
        if ($trackObj) {
            main::DEBUGLOG && $log->debug("AudioMuseMix Track seed " . $trackObj->path);
            push @seedsToUse, $trackObj;
        }
    } else {
        my $sql;
        my $col = 'track';
        my $param;
        my $dbh = Slim::Schema->dbh;
        my $minDuration = int($prefs->get('min_duration') || DEF_MIN_DURATION);
        my $maxDuration = int($prefs->get('max_duration') || DEF_MAX_DURATION);
        my $durationFilteredTracks = [];

        if ($request->getParam('artist_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT track FROM contributor_track WHERE contributor = ?} );
            $param = $request->getParam('artist_id');
        } elsif ($request->getParam('album_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT id FROM tracks WHERE album = ?} );
            $col = 'id';
            $param = $request->getParam('album_id');
        } elsif ($request->getParam('genre_id')) {
            $sql = $dbh->prepare_cached( qq{SELECT track FROM genre_track WHERE genre = ?} );
            $param = $request->getParam('genre_id');
        } else {
            $request->setStatusBadDispatch();
            return
        }

        $sql->execute($param);
        if ( my $result = $sql->fetchall_arrayref({}) ) {
            foreach my $res (@$result) {
                my ($track) = Slim::Schema->find('Track', $res->{$col});
                if ($track) {
                    if (($minDuration>0 && $track->secs<$minDuration) || ($maxDuration>0 && $track->secs>$maxDuration)) {
                        push @$durationFilteredTracks, $track;
                    } ele {
                        push @seedsToUse, $track;
                    }
                }
            }
        }

        # Too few tracks? Add some that were filtered due to duration
        if (scalar @seedsToUse < MIN_CLI_MIX_SEED_TRACKS && scalar @$durationFilteredTracks) {
            foreach my $track (@$durationFilteredTracks) {
                push @seedsToUse, $track;
                if (scalar @seedsToUse >= MIN_CLI_MIX_SEED_TRACKS) {
                    last;
                }
            }
        }

        if (scalar @seedsToUse > NUM_CLI_MIX_SEED_TRACKS) {
            Slim::Player::Playlist::fischer_yates_shuffle(\@seedsToUse);
            @seedsToUse = splice(@seedsToUse, 0, NUM_CLI_MIX_SEED_TRACKS);
        }

        foreach my $track (@seedsToUse) {
            main::DEBUGLOG && $log->debug("AudioMuseMix Track Seed " . $track->path);
        }
    }

    main::DEBUGLOG && $log->debug("Num tracks for AudioMuseMix: " . scalar(@seedsToUse));

    if (scalar @seedsToUse > 0) {
        my $respTracks = (scalar @seedsToUse) > 2 ? NUM_CLI_MIX_RESP_TRACKS : NUM_CLI_MIX_RESP_TRACKS_FEW;
        if ($origReqCount>0 && $respTracks>$origReqCount) {
            $respTracks = $origReqCount;
        }

        _generateMix(sub { _cliResponse(shift, $request, \@seedsToUse); }, $respTracks, \@seedsToUse, 0);
        $request->setStatusProcessing();
        return;
    }
    $request->setStatusBadDispatch();
}

sub _getSeedTracksFromQueue {
    my ($client, $count) = @_;

    return unless $client;

    $client = $client->master;

    my ($trackId, $artist, $title, $duration);
    my $tracks = [];
    my $durationFilteredTracks = [];
    my $pos = 0;
    my $count = int($prefs->get('num_seed_tracks') || DEF_NUM_SEED_TRACKS);
    my $strict = int($prefs->get('seed_strict_order') || 0);
    my $minDuration = int($prefs->get('min_duration') || DEF_MIN_DURATION);
    my $maxDuration = int($prefs->get('max_duration') || DEF_MAX_DURATION);
    my $minCount = $count && $count>4 ? $count-2 : $count;
    my $collectLimit = $strict ? $count : ($count * 2);

    # If set for only 1 seed track, and not set to be last, then choose randomly from last 4
    if (!$strict && $count==1) {
        $collectLimit = 4;
    }

    main::DEBUGLOG && $log->debug("Get seeds, minDuration:${minDuration}, maxDuration:${maxDuration}, minCount:${minCount}, count:${count}");
    # Get last tracks from queue (strict: exactly count, otherwise count*2)
    foreach my $track (reverse @{ Slim::Player::Playlist::playList($client) } ) {
        if (!blessed $track && Slim::Music::Info::isURL($track)) {
            $track = Slim::Schema->objectForUrl($track);
        }

        ($artist, $title, $duration, $trackId) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $track);

        # We reverse the queue (to get last N tracks) so need to check if 1st item in this list is radio
        if ($pos==0 && !$duration) {
            main::INFOLOG && $log->info("Found radio station last in the queue - don't start a mix.");
        }
        $pos++;

        next unless defined $artist && defined $title && 0==rindex($track->url, "file:", 0);

        if (($minDuration>0 && $duration<$minDuration) || ($maxDuration>0 && $duration>$maxDuration)) {
            push @$durationFilteredTracks, $track;
            next;
        }

        main::DEBUGLOG && $log->debug("..." . $track->url);
        push @$tracks, $track;
        if ($count && scalar @$tracks >= $collectLimit) {
            last;
        }
    }

    # Too few tracks? Add some that were filtered due to duration
    if ($minCount && scalar @$tracks < $minCount && scalar @$durationFilteredTracks) {
        foreach my $track (@$durationFilteredTracks) {
            push @$tracks, $track;
            if (scalar @$tracks >= $minCount) {
                last;
            }
        }
    }

    if (scalar @$tracks) {
        main::INFOLOG && $log->info($strict
            ? "Using last " . scalar(@$tracks) . " tracks from current playlist"
            : "Auto-mixing from random tracks in current playlist");

        if ($count && scalar @$tracks > $count) {
            Slim::Player::Playlist::fischer_yates_shuffle($tracks);
            @$tracks = splice(@$tracks, $count);
        }

        return $tracks;
    } elsif (main::INFOLOG && $log->is_info) {
        main::INFOLOG && $log->info("No mixable items found in current playlist!");
    }

    return;
}

# Unwrap a track list from any of the response shapes AudioMuse uses:
#   - bare array (similar_tracks, similar_artists, search_tracks,
#     sonic_fingerprint)
#   - { results: [...], ... }   (clap_search, lyrics_search, alchemy)
#   - { path: [...], total_distance } (find_path)
#   - { query_results: [...] } as a courtesy for any future caller that
#     forwards the chat-playlist response straight through.
# Returns an ARRAYREF (possibly empty) so callers can iterate without
# checking ref() each time.
sub _extractTracks { 
    my $data = shift;
    return $data if ref($data) eq 'ARRAY';
    return [] unless ref($data) eq 'HASH';
    for my $k (qw(results path query_results)) {
        return $data->{$k} if ref($data->{$k}) eq 'ARRAY';
    }       
    return []; 
}

sub _getTrackObjects {
    my ($data, $exclude) = @_;
    $exclude ||= {};
    my $tracks = _extractTracks($data);
    my @objs;
    for my $t (@$tracks) {
        my $id = $t->{item_id} // $t->{id};
        next unless defined $id && $id =~ /\A\d+\z/;
        next if $exclude->{$id};
        my $obj = eval { Slim::Schema->find('Track', $id) } or next;
        push @objs, $obj;
    }
    $log->info('Mix returning ' . scalar(@objs) . ' track(s)');
    return \@objs;
} 

sub _generateMix {
    my ($cb, $count, $seedTracks, $isDstm, $prevTracks) = @_;

    main::DEBUGLOG && $log->debug("Generate mix");

    my $filterXmas = int($prefs->get('filter_xmas') || 0);
    my $minDuration = int($prefs->get('min_duration') || DEF_MIN_DURATION);
    my $maxDuration = int($prefs->get('max_duration') || DEF_MAX_DURATION);
    my $noRepeatArtist = int($prefs->get('no_repeat_artist') || DEF_NO_REPEAT_ARTIST);
    my $noRepeatAlbum = int($prefs->get('no_repeat_album') || DEF_NO_REPEAT_ALBUM);
    my $matchAllGenres => int($prefs->get('match_all_genres') || 0);
    my $month = 0;

    if ($filterXmas) {
        my @lt = localtime;
        $month = $lt[4] + 1;
        if (12==$month) {
            $filterXmas = 0;
        }
    }

    my $reqCount = $count * 10;
    if ($reqCount<40) {
        $reqCount = 40;
    }

    if (scalar(@$seedTracks)>1) {
        my @useIds = ();
        foreach my $track (@$seedTracks) {
            push @useIds, $track->id;
        }
        main::DEBUGLOG && $log->debug("Invoke AudioMuse-AI alchemy API");
        Plugins::AudioMuseMixer::API::alchemy(
            \@useIds, [], $reqCount,
            sub { _processResponse(shift, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
            sub { $cb->([]); }
        );
    } else {
        my $api => int($prefs->get('api') || DEF_API);

        if (API_SEM_GROVE==$api) {
            main::DEBUGLOG && $log->debug("Invoke AudioMuse-AI sem_grove API");
            Plugins::AudioMuseMixer::API::sem_grove(
                @$seedTracks[0]->id, $reqCount,
                sub { _processResponse(shift, sub {
                    my $tracks = shift;
                    if (scalar(@$tracks)>1) {
                        $cb->($tracks);
                    } else {
                        main::DEBUGLOG && $log->debug("sem_grove returned no tracks, fallback to similar_tracks API");
                        Plugins::AudioMuseMixer::API::similar_tracks(
                            @$seedTracks[0]->id, $reqCount,
                            sub { _processResponse(shift, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                            sub { $cb->([]); }
                        );
                    }
                },$seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                sub {
                    main::DEBUGLOG && $log->debug("sem_grove failed, fallback to similar_tracks API");
                    Plugins::AudioMuseMixer::API::similar_tracks(
                        @$seedTracks[0]->id, $reqCount,
                        sub { _processResponse(shift, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                        sub { $cb->([]); }
                    );
                }
            );
        } elsif (API_HYPERBOLIC==$api) {
            main::DEBUGLOG && $log->debug("Invoke AudioMuse-AI similar_hyperbolic_tracks API");
            Plugins::AudioMuseMixer::API::similar_hyperbolic_tracks(
                @$seedTracks[0]->id, $reqCount,
                sub { _processResponse(shift, sub {
                    my $tracks = shift;
                    if (scalar(@$tracks)>1) {
                        $cb->($tracks);
                    } else {
                        main::DEBUGLOG && $log->debug("similar_hyperbolic_tracks returned no tracks, fallback to similar_tracks API");
                        Plugins::AudioMuseMixer::API::similar_tracks(
                            @$seedTracks[0]->id, $reqCount,
                            sub { _processResponse(shift, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                            sub { $cb->([]); }
                        );
                    }
                }, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                sub {
                    main::DEBUGLOG && $log->debug("similar_hyperbolic_tracks failed, fallback to similar_tracks API");
                    Plugins::AudioMuseMixer::API::similar_tracks(
                        @$seedTracks[0]->id, $reqCount,
                        sub { _processResponse(shift, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                        sub { $cb->([]); }
                    );
                }
            );
        } else {
            main::DEBUGLOG && $log->debug("Invoke AudioMuse-AI similar_tracks API");
            Plugins::AudioMuseMixer::API::similar_tracks(
                @$seedTracks[0]->id, $reqCount,
                sub { _processResponse(shift, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) },
                sub { $cb->([]); }
            );
        }
    }
}

sub _genreInGroup {
    my ($track, $genres, $matchAll) = @_;
    my $found = 0;
    foreach my $genre ($track->genres) {
        my $name = $genre->name;
        if (exists($genres->{$name})) {
            $found=1;
            if (!$matchAll) {
                return 1;
            }
        } elsif ($matchAll) {
            return 0;
        }
    }
    return $found;
}

sub _processResponse {
    my ($data, $cb, $seedTracks, $count, $filterXmas, $month, $minDuration, $maxDuration, $noRepeatArtist, $noRepeatAlbum, $matchAllGenres, $isDstm, $prevTracks) = @_;
    my @excludeIds = ();
    my %titles = ();
    my %artists = ();
    my %albums = ();

    # Init genre groups and exclusions - may have changed
    _initGenreGroups();
    _initExcludeArtists();
    _initExcludeAlbums();

    my $filterGenreGroups = scalar($genreGroups)>0;
    # Genres (from grouping) of seed tracks
    my %acceptableGenres = ();
    # All genres in genre groups - in case no seed track in genre group
    my %nonAcceptableGenres = ();
    my $filterViaAcceptable = 1;
    my $pos = 0;

    main::DEBUGLOG && $log->debug("Process response");
    if ($prevTracks) {
        foreach my $track (@$prevTracks) {
            push @excludeIds, $track->id;
            my $title = $track->title;
            my $artist = $track->artistid;
            my $album = $track->albumid;
            $titles{$title} = $pos;
            $artists{$artist} = $pos;
            $albums{$album} = $pos;
            $pos+=1;
        }
    }
    if ($seedTracks) {
        my @filterGenres = ();
        foreach my $track (@$seedTracks) {
            push @excludeIds, $track->id;
            if ($filterGenreGroups) {
                main::DEBUGLOG && $log->debug("Get acceptable genres");
                foreach my $hashRef (@$genreGroups) {
                    if  (_genreInGroup($track, $hashRef, $matchAllGenres)) {
                        foreach my $genre (keys %$hashRef) {
                            push @filterGenres, $genre;
                        }
                    }
                }
            }
        }
        %acceptableGenres = map { $_ => 1 } @filterGenres;
        $filterViaAcceptable = scalar(@filterGenres)>0;
        main::DEBUGLOG && $log->debug("Acceptable genres: " . Data::Dump::dump(%acceptableGenres));

        # Seed genres non in genre groups? Then need to exclude those genres
        if (!$filterViaAcceptable) {
            my @allGenresInGroups = ();
            foreach my $hashRef (@$genreGroups) {
                foreach my $genre (keys %$hashRef) {
                    push @allGenresInGroups, $genre;
                }
            }
            %nonAcceptableGenres = map { $_ => 1 } @allGenresInGroups;
            main::DEBUGLOG && $log->debug("Non-acceptable genres: " . Data::Dump::dump(%nonAcceptableGenres));
        }
    } else {
        $filterGenreGroups = 0;
    }
    my %exclude = map { $_ => 1 } @excludeIds;
    my $tracks = _getTrackObjects($data, \%exclude);
    my @usable = ();

    if ($tracks && scalar(@$tracks)>$count) {
        my @excludedDueToArtist = ();
        my @excludedDueToAlbum = ();
        my @filteredOutDueToArtist = ();
        my @filteredOutDueToAlbum = ();

        foreach my $track (@$tracks) {
            if (($minDuration>0 && $track->secs<$minDuration) || ($maxDuration>0 && $track->secs>$maxDuration)) {
                main::DEBUGLOG && $log->debug("FILTER (duration): " . $track->url);
                next;
            }
            my @genres = $track->genres;
            my $skip = 0;
            if ($filterXmas) {
                foreach my $genre (@genres) {
                    if (exists($XMAS_GENRES{$genre->name})) {
                        $skip = 1;
                        last;
                    }
                }
            }
            if ($skip) {
                main::DEBUGLOG && $log->debug("FILTER (xmas): " . $track->url);
                next;
            }

            my $title = $track->title;
            my $artist = $track->artistid;
            my $album = $track->albumid;

            if (exists($excludeArtists{$artist})) {
                main::DEBUGLOG && $log->debug("EXCLUDE (artist): " . $track->url);
                push @excludedDueToArtist, $track;
                next;
            }

            if (exists($excludeAlbums{$album})) {
                main::DEBUGLOG && $log->debug("EXCLUDE (album): " . $track->url);
                push @excludedDueToAlbum, $track;
                next;
            }

            if (exists($titles{$title})) {
                main::DEBUGLOG && $log->debug("FILTER (title): " . $track->url);
                next;
            }

            if ($filterGenreGroups &&
                ( ($filterViaAcceptable && !_genreInGroup($track, \%acceptableGenres, $matchAllGenres)) ||
                  (!$filterViaAcceptable && _genreInGroup($track, \%nonAcceptableGenres, 0)) ) ) {
                main::DEBUGLOG && $log->debug("FILTER (genre): " . $track->url);
                next;
            }

            if ($noRepeatArtist>0 && exists($artists{$artist}) && $pos-$artists{$artist}<=$noRepeatArtist) {
                main::DEBUGLOG && $log->debug("FILTER (artist): " . $track->url);
                push @filteredOutDueToArtist, $track;
                next;
            }

            if ($noRepeatAlbum>0 && $artist!=Slim::Schema->variousArtistsObject->id && exists($albums{$album}) && $pos-$albums{$album}<=$noRepeatAlbum) {
                main::DEBUGLOG && $log->debug("FILTER (album): " . $track->url);
                push @filteredOutDueToAlbum, $track;
                next;
            }

            $titles{$title} = $pos;
            $artists{$artist} = $pos;
            $albums{$album} = $pos;

            main::DEBUGLOG && $log->debug("USABLE: " . $track->url);
            push @usable, $track->url;
            $pos += 1;
        }

        my $total = scalar(@usable);
        if ($total<=$count) {
            if ($total<$count) {
                foreach my $track (@filteredOutDueToArtist) {
                    push @usable, $track->url;
                    if (scalar(@usable)>=$count) {
                        last;
                    }
                }
                if (scalar(@usable)<$count) {
                    foreach my $track (@filteredOutDueToAlbum) {
                        push @usable, $track->url;
                        if (scalar(@usable)>=$count) {
                            last;
                        }
                    }
                }
            }
            if ($total<1) {
                if (scalar(@excludedDueToAlbum)>0) {
                    push @usable, $excludedDueToAlbum[0]->url;
                } elsif (scalar(@excludedDueToArtist)>0) {
                    push @usable, $excludedDueToArtist[0]->url;
                }
            }
        }
        if (scalar(@usable)>($count * 2)) {
            @usable = splice(@usable, 0, $count * 2);
        }
        Slim::Player::Playlist::fischer_yates_shuffle(\@usable);
        if (scalar(@usable)>$count) {
            @usable = splice(@usable, 0, $count);
        }
    } else {
        Slim::Player::Playlist::fischer_yates_shuffle($tracks);
        foreach my $track (@$tracks) {
            push @usable, $track->url;
        }
    }
    foreach my $track (@usable) {
        main::DEBUGLOG && $log->debug("Use track: ${track}");
    }
    $cb->(\@usable);
}

sub _mixFailed {
    my ($client, $cb) = @_;

   if (exists $INC{'Plugins/LastMix/DontStopTheMusic.pm'}) {
        main::DEBUGLOG && $log->debug("Call through to LastMix");
        Plugins::LastMix::DontStopTheMusic::please($client, $cb);
    } else {
        main::DEBUGLOG && $log->debug("Return empty list");
        $cb->($client, []);
    }
}

sub _getPreviousTracks {
    my ($client, $count) = @_;
    main::DEBUGLOG && $log->debug("Get last " . $count . " tracks");
    return unless $client;

    $client = $client->master;

    my $tracks = ();
    if ($count>0) {
        for my $track (reverse @{ Slim::Player::Playlist::playList($client) } ) {
            if (!blessed $track) {
                $track = Slim::Schema->objectForUrl($track);
            }

            next unless blessed $track;

            unshift @$tracks, $track;
            if (scalar @$tracks >= $count) {
                return $tracks;
            }
        }
    }
    return $tracks;
}

sub _initGenreGroups {
    # Check to see if config has changed, saves having to read and process each time
    my $ggTs = $prefs->get('_ts_genre_groups');
    my $utgTs = $prefs->get('_ts_use_track_genre');
    if ($ggTs==$genreGroupsTs && $utgTs==$useTrackGenreTs) {
        return;
    }
    $genreGroupsTs = $ggTs;
    $useTrackGenreTs = $utgTs;
   
    $genreGroups = [];
    my %genresInGroups = ();
    my $ggpref = $prefs->get('genre_groups');
    if ($ggpref) {
        my @lines = split(/\n/, $ggpref);
        if (scalar(@lines)>0) {
            foreach my $line (@lines) {
                my @genreGroup = split(/\;/, $line);
                my @grp = ();
                foreach my $genre (@genreGroup) {
                    # left trim
                    $genre=~ s/^\s+//;
                    # right trim
                    $genre=~ s/\s+$//;
                    if (length $genre > 0) {
                        push(@grp, $genre);
                        $genresInGroups{$genre}=1;
                    }
                }
                if (scalar(@grp) > 0) {
                    my %hash = map { $_ => 1 } @grp;
                    push(@$genreGroups, \%hash);
                }
            }
        }
    }
    if ($prefs->get('use_track_genre')) {
        # Create 'group' of single genres...
        my $request = Slim::Control::Request::executeRequest(undef, ["genres", 0, 5000] );
        foreach my $genre ( @{ $request->getResult('genres_loop') || [] } ) {
            my $name = $genre->{name};
            if ($name && (not exists($genresInGroups{$name}))) {
                $genresInGroups{$name}=1;
                my @grp = ();
                push(@grp, $name);
                my %hash = map { $_ => 1 } @grp;
                push(@$genreGroups, \%hash);
            }
        }
    }
    main::DEBUGLOG && $log->debug("GENRE GROUPS: " . Data::Dump::dump($genreGroups));
}

sub _initExcludeArtists {
    # Check to see if config has changed, saves having to read and process each time
    my $ts = $prefs->get('_ts_exclude_artists');
    if ($ts==$excludeArtistsTs ) {
        return;
    }
    $excludeArtistsTs = $ts;
    my $exPref = $prefs->get('exclude_artists');
    my @ids = ();
    if ($exPref) {
        my @lines = split(/\n/, $exPref);
        if (scalar(@lines)>0) {
            my $dbh = Slim::Schema->dbh;
            my $sql = $dbh->prepare_cached( qq{SELECT id FROM contributors WHERE name = ?} );
            foreach my $line (@lines) {
                $line=~ s/^\s+//;
                $line=~ s/\s+$//;
                if (length $line > 0) {
                    main::DEBUGLOG && $log->debug("Exclude artist ${line}");
                    $sql->execute($line);
                    if ( my $result = $sql->fetchall_arrayref({}) ) {
                        foreach my $res (@$result) {
                            main::DEBUGLOG && $log->debug(" -> " . $res->{'id'});
                            push @ids, $res->{'id'}
                        }
                    }
                }
            }
        }
    }
    %excludeArtists = map { $_ => 1 } @ids;
}

sub _initExcludeAlbums {
    # Check to see if config has changed, saves having to read and process each time
    my $ts = $prefs->get('_ts_exclude_albums');
    if ($ts==$excludeAlbumsTs ) {
        return;
    }
    $excludeAlbumsTs = $ts;
    my $exPref = $prefs->get('exclude_albums');
    my @ids = ();
    if ($exPref) {
        my @lines = split(/\n/, $exPref);
        if (scalar(@lines)>0) {
            my $dbh = Slim::Schema->dbh;
            my $artistSql = $dbh->prepare_cached( qq{SELECT id FROM contributors WHERE name = ?} );
            my $artistAlbumSql = $dbh->prepare_cached( qq{SELECT id FROM albums WHERE contributor = ? AND title = ?} );
            my $albumSql = $dbh->prepare_cached( qq{SELECT id FROM albums WHERE title = ?} );
            foreach my $line (@lines) {
                $line=~ s/^\s+//;
                $line=~ s/\s+$//;
                if (length $line > 0) {
                    my @parts = split(/\/\//, $line);
                    if (2==scalar(@parts)) {
                        main::DEBUGLOG && $log->debug("Exclude album " . $parts[1] . " by " . $parts[0]);
                        $artistSql->execute($parts[0]);
                        if ( my $artistRes = $artistSql->fetchall_arrayref({}) ) {
                            foreach my $ares (@$artistRes) {
                                $artistAlbumSql->execute($ares->{'id'}, $parts[1]);
                                if ( my $albumRes = $artistAlbumSql->fetchall_arrayref({}) ) {
                                    foreach my $res (@$albumRes) {
                                        main::DEBUGLOG && $log->debug(" -> " . $res->{'id'});
                                        push @ids, $res->{'id'}
                                    }
                                }
                            }
                        }
                    } else {
                        main::DEBUGLOG && $log->debug("Exclude album ${line}");
                        $albumSql->execute($line);
                        if ( my $result = $albumSql->fetchall_arrayref({}) ) {
                            foreach my $res (@$result) {
                                main::DEBUGLOG && $log->debug(" -> " . $res->{'id'});
                                push @ids, $res->{'id'}
                            }
                        }
                    }
                }
            }
        }
    }
    %excludeAlbums = map { $_ => 1 } @ids;
}

sub _notifyFromScanner {
    my $request = shift;              
    my $msg = $request->getParam('_msg');
    if ( $msg eq 'exit' ) {
        # Scan may change genre IDs, so need to invalidate genre groups
        $genreGroupsTs = 0;
        $excludeArtistsTs = 0;
        $excludeAlbumsTs = 0;
    }
    $request->setStatusDone();
}

1;

__END__
