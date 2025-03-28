# Tecs Project Guide for Claude

## Project Overview

Tecs is a high-performance Entity Component System (ECS) framework written in Teal (a typed dialect of Lua),
designed specifically for LuaJIT with FFI, but with seamless fallback for Lua 5.1+. It provides a type-safe,
cache-friendly ECS implementation optimized for game development with LÖVE2D (though it isn't coupled to LÖVE2D).

## Technology Stack

- **Language**: Teal (.tl files) - A typed dialect of Lua
- **Runtime**: LuaJIT with FFI (with a pure Lua fallback)
- **Build System**: Make + Cyan (Teal's build tool)
- **Testing**: Busted test framework (make test)
- **Documentation**: Vite-based documentation site in `docs/`
- **Target Platform**: LÖVE2D games on desktop and mobile

## Key Commands

### Makefile

```bash
make clean  # Clean build artifacts
make        # Build the project (compiles .tl to .lua)
make all    # Build and run tests
make check  # Type check without building
cyan build  # Alternative: Direct Teal compilation
make test   # Run all tests (builds first, then runs Busted)
```

### Documentation

```bash
cd docs
npm install  # First time setup
npm run dev  # Start local documentation server
npm run build  # Build documentation site
```

## Project Structure

```
tecs/
├── src/
│   ├── tecs/           # Core ECS implementation
│   │   ├── internal/   # Internal modules (not for direct use)
│   │   │   ├── Archetype.tl      # Archetype storage
│   │   │   ├── changes.tl        # Transaction system
│   │   │   ├── ecs.tl            # Core ECS container
│   │   │   ├── EntityIndex.tl    # Entity lookups
│   │   │   └── ...
│   │   └── init.tl     # Main module entry point
│   ├── tecs2d/         # Love 2D game extensions
│   └── stagecoach/     # Asset loading system
├── spec/               # Test files (*_spec.tl)
├── docs/               # Documentation site
│   ├── reference/      # API reference docs
│   └── guide/          # User guides
├── build/              # Compiled Lua files (generated)
└── Makefile           # Build configuration
```

## Core Architecture Decisions

### 1. Based on proven ECS architectures

Tecs follows the proven architectural patterns of frameworks like Flecs and Bevy, but we are willing to deviate or
completely change the approach in Tecs to get the best architecture and performance for Lua and LuaJIT.

### 1. LuaJIT/FFI Recommended but not required

- Pure data components use typed FFI arrays (Position, Velocity, Health), but fallback to Lua tables
- Components with Lua/LÖVE references remain as tables (Sprite, Script)
- Use bulk operations use `ffi.copy()` for performance
- Memory management via FFI enables predictable performance

### 2. Entity ID System

- Monotonically increasing IDs - Simple incrementing counter, never reused
- No generation/version encoding - entities are never recycled
- IDs start at 1 (Lua convention)
- Can be used as direct array indices in FFI buffers
- It would take hundreds of years to run out of IDs

### 3. Immutable Spawns

- Entities cannot be mutated in the same frame they're spawned
- This is a performance optimization, simplification, and correctness optimization
- Attempting spawn-then-mutate throws an error
- Enables staging archetype optimization and bulk operations
- Forces users to build complete entity definitions before spawning

### 4. Transaction System

- All changes within a system are deferred until system completion
- Staging archetypes group spawns by component composition
- Can be promoted to real archetypes (zero-copy) or bulk-copied
- After warmup, achieves zero allocations per frame

### 5. Memory Architecture

- Shared page pool - Global pool of reusable memory pages
- Frame arena - Per-frame allocations, resets instantly
- Staging archetype pooling - Reuse between frames
- Component pools - Size-bucketed for archetype growth

## Development Guidelines

### 1. Type Safety

- Always use proper Teal typing
- Use generics where appropriate for reusability
- Minimize `as` casts unless avoiding significant complexity

### 2. Testing Requirements

**Add tests when:**
- Adding new functionality
- Fixing bugs (add test that would have caught the bug)
- Making logic changes
- Modifying edge case handling (unless it requires too much setup)

**Test files:**
- Located in `spec/` directory
- Named `*_spec.tl`
- Use Busted framework with luassert
- Tests are written with Teal not Lua

**Test Compilation Requirements**
- All test files MUST compile without errors before considering any task complete
- The `make test` command will fail immediately if any test has compilation errors

**Example test structure:**

```lua
describe("module name", function()
    describe("feature", function()
        it("should do something", function()
            -- Arrange
            local input = ...

            -- Act
            local result = functionUnderTest(input)

            -- Assert
            luassert.is_equal(expected, result)
        end)
    end)
end)
```

### 3. Documentation Updates

**Update documentation when:**
- Changing public API behavior
- Adding new modules or features
- Modifying configuration options
- Changing system requirements

### 4. Code Style

- Use 4-space indentation
- Keep line length under 120 characters
- Trim trailing spaces, including on empty lines
- Use `local` for all variables. Pretend global doesn't exist
- Use `<const>` annotation for immutable values
- Prefer early returns over deep nesting
- Add type annotations for all public functions
- Don't add too many code comments. AI tends to over-comment.
- Avoid em-dashes. Avoid " - " too and prefer commas, semicolons, colons, etc

### 5. Performance Considerations

- This is a performance-critical ECS framework
- Avoid allocations in hot paths: use pooling and arenas
- Design for cache locality with struct-of-arrays layout
- Batch operations wherever possible
- Profile before optimizing, but design for performance from the start

### 6. Common Patterns

**Constants:**
```lua
local MAX_ENTITIES <const> = 2097151
```

**Error Messages (guide users to performance):**
```lua
error("Cannot mutate entity spawned this frame - include all components in spawn() for bulk optimization")
```

**Module Structure:**
```lua
local record modulename
    -- Type definitions
end

-- Implementation
function modulename.new()
    -- Constructor
end

return modulename
```

## Common Tasks

### Adding a New Component

1. Decide if it should be FFI (pure data) or table (references)
2. Define component in appropriate module
3. Add tests in `spec/`
4. Consider storage strategy (lazy, pooled, etc.)
5. Update documentation if public API

### Optimizing a System

1. Profile first to identify bottlenecks
2. Check for allocation in hot loops
3. Create queries outside of systems
4. Ensure cache-friendly access patterns

## Troubleshooting

**Build errors:**
- For optimal performance, verify LuaJIT is installed (Lua 5.1+ works with automatic fallbacks)
- Check FFI availability with `require("ffi")` for performance debugging
- Run `make clean` first
- Check Teal syntax in .tl files
- Verify all type annotations

**Test failures:**
- Read failure message carefully
- Check if implementation matches test expectations
- Verify test data is correct

## Resources
- [Teal Language Documentation](https://github.com/teal-language/tl)
- [LuaJIT FFI Tutorial](https://luajit.org/ext_ffi_tutorial.html)
- [LuaJIT Extensions](https://luajit.org/extensions.html)
- [Busted Testing Framework](https://olivinelabs.com/busted/)
- [LÖVE2D Reference](https://love2d.org/wiki/Main_Page)
- [ECS Architecture Patterns](https://github.com/SanderMertens/ecs-faq)