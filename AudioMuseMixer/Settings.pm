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
    return ($prefs, 'url', 'auth_key', 'timeout', 'filter_genres', 'filter_xmas', 'min_duration', 'max_duration', 'no_repeat_artist',
                    'no_repeat_album', 'no_repeat_track', 'dstm_tracks', 'genre_groups', 'use_track_genre', 'num_seed_tracks',
                    'seed_strict_order', 'match_all_genres');
}

sub handler {
    my ($class, $client, $paramRef) = @_;
    for my $setting (
        ['pref_lastfm_weighting_weight', 0, 100],
        ['pref_playcount_influence', -100, 100],
    ) {
        my ($name, $minimum, $maximum) = @$setting;
        next unless defined $paramRef->{$name};
        my $value = int($paramRef->{$name});
        $value = $minimum if $value < $minimum;
        $value = $maximum if $value > $maximum;
        $paramRef->{$name} = $value;
    }
    return $class->SUPER::handler($client, $paramRef);
}

1;

__END__
