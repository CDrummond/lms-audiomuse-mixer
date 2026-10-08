# AudioMuse Mixer

LMS `Don't Stop The Music` plugin using [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI)
to provide similar tracks to seed tracks chosen from the current play queue.

All tracks must have first been analysed with [AudioMuse-AI](https://github.com/NeptuneHub/AudioMuse-AI).
If a mix fails then this mixer will fall back to LMS's Last.fm mixer.


# LMS menus

1 entry is added to LMS' 'More'/context menus:

1. `Create AudioMuse mix` creates a mix tracks based upon the selected
artist, album, or track, returned in a shuffled order.

*NOTE* This menu does not currently work with the `Default` LMS web skin, but does
work with `Material Skin` and other controllers.


# URL for favourites, etc.

The mixer can be started via the `audiomusemixer://` URL. This supports the following query items:

1. `artist` URL encoded artist name
2. `album` URL encoded album name
3. `path` URL encoded track path
4. `genre` URL encoded genre name
5. `count` number of tracks to return
6. `dstm` if set to `1` then `DSTM` is enabled for the player and set to `AudioMuse`

To start a mix based upon an artist, 15 tracks, and enable DSTM:
```
audiomusemixer://?artist=Iron%20Maiden&count=15&dstm=1
```

To start a mix based upon an album, then **both** `artist` and `album` must be specified:
```
audiomusemixer://?artist=Iron%20Maiden&album=Somewhere%20In%20Time
```

To start a mix based upon a single track:
```
audiomusemixer://?path=%2Fmedia%2Fmusic%2FIron%20Maiden%2FSomewhere%20In%20Time%2F02%20Wasted%20Years.mp3

```

To start a mix based upon a genre:
```
audiomusemixer://?genre=Heavy%20Metal

```

**NOTE** For safety strings should be URL escaped, as shown in the examples above. However, if they do not contain `?`, `&`, `=`, or `#`, it *might* be OK to use the plain strings - e.g.

```
audiomusemixer://?artist=Iron Maiden&album=Somewhere In Time
```


# Installation

Add the following as a 3rd party repository URL in LMS:

```url
https://raw.githubusercontent.com/CDrummond/lms-audiomuse-mixer/refs/heads/master/public.xml
```
