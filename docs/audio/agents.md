---
description: "Inspect, record and drive the audio console from the MCP debug server"
order: 52
---

# Audio for agents

An agent cannot hear, so the debug server reports the console as data and
records what was played. A memory output, or a void one held by `clock_pause`,
makes all of it deterministic: the audio clock then moves only with the frames
`clock_step` grants, or with `audio_step`.

| Tool              | What it does                                                                                                             |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `audio`           | Installed, available, failure, voice count, master gain, decoders                                                        |
| `audio_snapshot`  | Buses and Tracks with their faders, sends, effects and meters; voices; Timelines; the clock, the output and the counters |
| `audio_events`    | Starts, refusals, steals, stops and finishes, each with its clock time; pass `after` to read only what is new            |
| `audio_listen`    | Starts recording the next `seconds` of the mix                                                                           |
| `audio_listening` | Summarizes the recording: peak, RMS, LUFS, clipped samples, silent spans and onset times; `save` writes a WAV            |
| `audio_step`      | Renders `seconds` of a memory or held void output                                                                        |
| `audio_control`   | Sets a Bus's or a Track's gain, mute, solo or pause                                                                      |
| `audio_play`      | Plays a loaded clip on a Bus or a Track, now or at a clock time                                                          |
| `audio_timeline`  | Pauses, resumes, seeks or retempos a Timeline                                                                            |
| `reload_sound`    | Reloads a cached clip from its file                                                                                      |

To check "did the door sound play when the door opened": `clock_pause`, open
the door, `clock_step`, then read `audio_events` for its start and
`audio_listening` for an onset near that time.
