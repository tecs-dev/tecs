# Tecs_Render Demo

A simple interactive demo showcasing the tecs_render rendering pipeline features.

## Features Demonstrated

- **Dynamic Lighting**: Mouse cursor acts as a flickering light source
- **Layer System**: Named layers for ground, entities, effects, and HUD
- **Camera Movement**: Arrow key navigation through a large world
- **Scale Modes**: Cycle through aspect, pixel, stretch, and none modes
- **Unlit Objects**: Some rectangles ignore lighting, click to toggle
- **Interactive Elements**: Hover and click rectangles to change lighting
- **Coordinate Systems**: Shows both camera and mouse world coordinates

## Running the Demo

From the tecs project root:
```bash
make tecs_render-example
```

Or manually:
```bash
./examples/tecs_render-showcase/run.sh
```

## Controls

- **Arrow Keys**: Move camera around the world
- **Z/X**: Zoom in/out
- **P**: Cycle through scale modes (aspect/pixel/stretch/none)
- **L**: Toggle lighting on/off
- **F**: Toggle fullscreen
- **1-4**: Show/hide individual layers
- **A/S**: Make ambient light darker/brighter
- **Mouse**: Light follows cursor, illuminating rectangles
- **Click**: Toggle whether a rectangle is affected by lighting
- **Hover**: Temporarily makes rectangle unlit
- **ESC**: Quit

## What to Look For

1. **Lighting Effects**: Notice how the mouse light illuminates rectangles based on distance
2. **Unlit Objects**: Some rectangles stay bright even in darkness
3. **Scale Modes**: Press P to see different rendering modes
4. **Performance**: Thousands of objects with real-time lighting
5. **Layer Visibility**: Toggle layers with number keys to see the system
6. **Zoom Quality**: The high oversample (3x) keeps graphics crisp when zoomed

## Technical Details

- Uses tecs_render's named layers feature
- Demonstrates the UNLIT_FLAG for UI and special objects
- Shows coordinate conversion (screen to world)
- Implements all 4 scale modes
- Real-time ambient light adjustment
- Efficient culling (only renders visible tiles/rectangles)