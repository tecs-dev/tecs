# Tecs Audio Example

A demonstration of the tecs.audio module's 3D spatial audio capabilities.

## Features

- **Spatial Audio**: Sound sources positioned in 2D space with distance-based volume attenuation
- **Multiple Emitters**: Five sound-emitting shapes with different frequencies
- **Player Movement**: Move the listener (white square) with WASD or arrow keys
- **Visual Feedback**: Shapes brighten as you get closer
- **Volume Control**: Mute toggle and volume adjustment

## Controls

| Key | Action |
|-----|--------|
| WASD / Arrows | Move player |
| M | Toggle mute |
| +/- | Adjust volume |
| ESC | Quit |

## Running

From the tecs project root:

```bash
./examples/audio/run.sh
```

## How It Works

- The **white square** is the player and audio listener
- **Colored circles** are sound emitters, each playing a different tone
- Move closer to hear sounds louder, move away to hear them fade
- Each emitter has a `refDistance` (full volume) and `maxDistance` (silent)

## Sound Sources

| Color | Tone | Frequency |
|-------|------|-----------|
| Red | Bass Hum | 110 Hz (A2) |
| Green | Mid Tone | 220 Hz (A3) |
| Blue | High Tone | 440 Hz (A4) |
| Yellow | Bright Tone | 660 Hz (E5) |
| Magenta | Center | 220 Hz (A3) |
