import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "Tecs",
  description: "Typed entity component system and game framework for Lua.",
  markdown: {
    theme: {
      light: 'github-light',
      // 'andromeeda' | 'aurora-x' | 'ayu-dark' | 'catppuccin-frappe' | 'catppuccin-latte' | 'catppuccin-macchiato' | 'catppuccin-mocha' | 'dark-plus' | 'dracula' | 'dracula-soft' | 'everforest-dark' | 'everforest-light' | 'github-dark' | 'github-dark-default' | 'github-dark-dimmed' | 'github-dark-high-contrast' | 'github-light' | 'github-light-default' | 'github-light-high-contrast' | 'houston' | 'kanagawa-dragon' | 'kanagawa-lotus' | 'kanagawa-wave' | 'laserwave' | 'light-plus' | 'material-theme' | 'material-theme-darker' | 'material-theme-lighter' | 'material-theme-ocean' | 'material-theme-palenight' | 'min-dark' | 'min-light' | 'monokai' | 'night-owl' | 'nord' | 'one-dark-pro' | 'one-light' | 'plastic' | 'poimandres' | 'red' | 'rose-pine' | 'rose-pine-dawn' | 'rose-pine-moon' | 'slack-dark' | 'slack-ochin' | 'snazzy-light' | 'solarized-dark' | 'solarized-light' | 'synthwave-84' | 'tokyo-night' | 'vesper' | 'vitesse-black' | 'vitesse-dark' | 'vitesse-light'
      dark: 'tokyo-night'
    }
  },
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/images/logo.svg' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    ['link', { href: 'https://fonts.googleapis.com/css2?family=Jersey+15&display=swap', rel: 'stylesheet' }]
  ],
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config

    logo: '/images/logo.svg',
    siteTitle: false,

    search: {
      provider: 'local'
    },

    sidebar: [
      {
        text: 'Tecs',
        collapsed: true,
        items: [
          { text: 'Getting Started', link: '/tecs/' },
          { text: 'World', link: '/tecs/world' },
          { text: 'Phases', link: '/tecs/phases' },
          { text: 'Systems', link: '/tecs/systems' },
          {
            text: 'Queries',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs/queries/' },
              { text: 'Callbacks', link: '/tecs/queries/callbacks' },
              { text: 'Grouping', link: '/tecs/queries/grouping' },
            ]
          },
          {
            text: 'Components',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs/components/' },
              { text: 'Component Construction', link: '/tecs/components/construction' },
              { text: 'Table Components', link: '/tecs/components/table-components' },
              { text: 'Tag Components', link: '/tecs/components/tag-components' },
              { text: 'Scalar Components', link: '/tecs/components/scalar-components' },
              { text: 'FFI Components', link: '/tecs/components/ffi' },
              { text: 'Bundles', link: '/tecs/components/bundles' },
              { text: 'Serialization', link: '/tecs/components/serialization' },
              { text: 'Dirty Tracking', link: '/tecs/components/dirty-tracking' },
            ]
          },
          {
            text: 'Relationships',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs/relationships/' },
              { text: 'Tag Relationships', link: '/tecs/relationships/tag' },
              { text: 'FFI Relationships', link: '/tecs/relationships/ffi' },
            ]
          },
          { text: 'Archetypes', link: '/tecs/archetype' },
          { text: 'Events', link: '/tecs/events' },
          { text: 'States', link: '/tecs/states' },
          { text: 'Builtins', link: '/tecs/builtins' },
          { text: 'Save games', link: '/tecs/save-games' },
          {
            text: 'Utilities',
            collapsed: true,
            items: [
              { text: 'JSON', link: '/tecs/utils/json' },
              { text: 'Logging', link: '/tecs/utils/logging' },
              { text: 'Profiling', link: '/tecs/utils/profiling' },
            ]
          },
        ]
      },
      {
        text: 'Tecs2D',
        collapsed: true,
        items: [
          { text: 'Getting Started', link: '/tecs2d/' },
          { text: 'Love2D Integration', link: '/tecs2d/love2d' },
          { text: 'Love2D Events', link: '/tecs2d/events' },
          {
            text: 'Input & Controls',
            collapsed: true,
            items: [
              { text: 'Input Handling', link: '/tecs2d/input/' },
              {
                text: 'Controller',
                collapsed: true,
                items: [
                  { text: 'Overview', link: '/tecs2d/input/controller/' },
                  { text: 'Bindings', link: '/tecs2d/input/controller/bindings' },
                  { text: 'Gamepad Support', link: '/tecs2d/input/controller/gamepad' },
                  { text: 'API Reference', link: '/tecs2d/input/controller/api' },
                ]
              },
            ]
          },
          {
            text: 'Rendering',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs2d/rendering/' },
              { text: 'Camera', link: '/tecs2d/rendering/camera' },
              { text: 'Shapes', link: '/tecs2d/rendering/shapes' },
              { text: 'Text', link: '/tecs2d/rendering/text' },
              { text: 'Styling', link: '/tecs2d/rendering/styling' },
              { text: 'Layers', link: '/tecs2d/rendering/layers' },
              { text: 'Lighting', link: '/tecs2d/rendering/lighting' },
              {
                text: 'Sprites',
                collapsed: true,
                items: [
                  { text: 'Overview', link: '/tecs2d/rendering/sprites/' },
                  { text: 'Sprite Sheets', link: '/tecs2d/rendering/sprites/sheets' },
                  { text: 'Animation', link: '/tecs2d/rendering/sprites/animation' },
                  { text: 'Slices & Pivots', link: '/tecs2d/rendering/sprites/slices' },
                  { text: 'Collisions', link: '/tecs2d/rendering/sprites/collisions' },
                  { text: 'Events', link: '/tecs2d/rendering/sprites/events' },
                  { text: 'Tiling', link: '/tecs2d/rendering/sprites/tiling' },
                ]
              },
              { text: 'Materials', link: '/tecs2d/rendering/materials' },
              { text: 'Particles', link: '/tecs2d/rendering/particles' },
              {
                text: 'UI',
                collapsed: true,
                items: [
                  { text: 'Overview', link: '/tecs2d/rendering/ui/' },
                  { text: 'Anchor', link: '/tecs2d/rendering/ui/anchor' },
                  { text: 'LayoutBox', link: '/tecs2d/rendering/ui/layoutbox' },
                  { text: 'LayoutNode', link: '/tecs2d/rendering/ui/layoutnode' },
                  { text: 'ClipBounds', link: '/tecs2d/rendering/ui/clipbounds' },
                  { text: 'FitContent', link: '/tecs2d/rendering/ui/fitcontent' },
                  { text: 'Helpers', link: '/tecs2d/rendering/ui/helpers' },
                ]
              },
              { text: 'Custom Drawing', link: '/tecs2d/rendering/custom-drawing' },
            ]
          },
          {
            text: 'Assets',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs2d/assets/' },
              { text: 'API Reference', link: '/tecs2d/assets/api' },
            ]
          },
          {
            text: 'Audio',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs2d/audio/' },
              { text: 'Components', link: '/tecs2d/audio/components' },
              { text: 'API Reference', link: '/tecs2d/audio/api' },
            ]
          },
          {
            text: 'Tiled',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs2d/tiled/' },
              { text: 'Tilemap Component', link: '/tecs2d/tiled/tilemap' },
              { text: 'TileSource Component', link: '/tecs2d/tiled/tile-source' },
              { text: 'TileChunks', link: '/tecs2d/tiled/tile-chunks' },
              { text: 'Collision', link: '/tecs2d/tiled/collision' },
              { text: 'Debug Plugin', link: '/tecs2d/tiled/debug-plugin' },
              { text: 'Utility Functions', link: '/tecs2d/tiled/utility-functions' },
            ]
          },
          {
            text: 'Physics',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs2d/physics/' },
              { text: 'Components', link: '/tecs2d/physics/components' },
              { text: 'Collision Events', link: '/tecs2d/physics/collisions' },
              { text: 'Transform Smoothing', link: '/tecs2d/physics/smoothing' },
            ]
          },
          { text: 'Tween', link: '/tecs2d/tween' },
          { text: 'Stats Overlay', link: '/tecs2d/stats' },
          {
            text: 'MCP',
            collapsed: true,
            items: [
              { text: 'Overview', link: '/tecs2d/mcp/' },
              { text: 'Tools', link: '/tecs2d/mcp/tools' },
              { text: 'Dev-Mode Restart', link: '/tecs2d/mcp/dev-mode' },
            ]
          },
        ]
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/tecs-dev/tecs' }
    ],

    footer: {
      message: 'Released under the <a href="https://github.com/tecs-dev/tecs/blob/main/LICENSE">MIT License</a>.',
      copyright: 'Copyright © <a href="https://github.com/mtdowling">Michael Dowling</a>'
    }
  }
})
