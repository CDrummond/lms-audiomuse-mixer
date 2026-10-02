package Plugins::AudioMuseMixer::Settings;

#
# LMS AudioMuse Mixer
#
# (c) 2026 Craig Drummond
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.audiomusemixer',
    'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.audiomusemixer');
my $serverprefs = preferences('server');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('AudioMuseMixer');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/AudioMuseMixer/settings/audiomusemixer.html');
}

sub prefs {
    return ($prefs, 'url', 'token', 'server_name', 'api', 'filter_genres', 'filter_xmas', 'min_duration', 'max_duration', 'no_repeat_artist',
                    'no_repeat_album', 'no_repeat_track', 'dstm_tracks', 'genre_groups', 'use_track_genre', 'num_seed_tracks',
                    'seed_strict_order', 'match_all_genres', 'exclude_artists', 'exclude_albums');
}

sub handler {
    my ($class, $client, $params) = @_;
    if (defined $params->{pref_url}) {
        $params->{pref_url} = _normalizeUrl($params->{pref_url});
    }
    if (defined $params->{pref_token}) {
        my $t = _trim($params->{pref_token});
        $t = '' if $t =~ /[\r\n]/;
        $params->{pref_token} = $t;
    }
    if (defined $params->{pref_server_name}) {
        $params->{pref_server_name} = _trim($params->{pref_server_name});
    }
    for my $setting (
        ['pref_min_duration', 0, 3600],
        ['pref_max_duration', 0, 3600],
        ['pref_no_repeat_artist', 0, 200],
        ['pref_no_repeat_album', 0, 200],
        ['pref_no_repeat_track', 0, 200],
        ['pref_dstm_tracks', 2, 20],
        ['pref_num_seed_tracks', 1, 25],
        ['pref_api', 0, 2]
    ) {
        my ($name, $minimum, $maximum) = @$setting;
        next unless defined $params->{$name};
        my $value = int($params->{$name});
        $value = $minimum if $value < $minimum;
        $value = $maximum if $value > $maximum;
        $params->{$name} = $value;
    }

    return $class->SUPER::handler($client, $params);
}

1;

__END__
