# Tecs Examples

This directory contains examples demonstrating various Tecs features.

## Running Examples

From the tecs project root:

```bash
# Using the dynamic run target
make run-audio
make run-physics

# Or using legacy named targets
make example-audio
make example-physics

# Or directly
./examples/audio/run.sh
```

## Creating a New Example

1. Copy the template:
   ```bash
   cp -r examples/_template examples/my-feature
   ```

2. Edit `examples/my-feature/src/main.tl`

3. Update `examples/my-feature/conf.lua` with your window settings

4. Run it:
   ```bash
   make run-my-feature
   ```

## Example Structure

Every example follows this structure:

```
examples/my-feature/
├── tlconfig.lua     # Teal config (same for all examples)
├── conf.lua         # Love window config
├── build.sh         # Build script
├── run.sh           # Run script
├── src/
│   └── main.tl      # Main entry point
├── assets/          # Optional: images, sounds, maps
└── README.md        # Optional: example documentation
```

## CI Validation

All examples are validated in CI:

```bash
make check-examples  # Type check all examples
make build-examples  # Build all examples
```
