import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

// https://vitepress.dev/reference/site-config
export default withMermaid(defineConfig({
  title: "Tecs",
  description: "Typed entity component system and game framework for Lua.",
  markdown: {
    theme: {
      light: 'github-light',
      // 'andromeeda' | 'aurora-x' | 'ayu-dark' | 'catppuccin-frappe' | 'catppuccin-latte' | 'catppuccin-macchiato' | 'catppuccin-mocha' | 'dark-plus' | 'dracula' | 'dracula-soft' | 'everforest-dark' | 'everforest-light' | 'github-dark' | 'github-dark-default' | 'github-dark-dimmed' | 'github-dark-high-contrast' | 'github-light' | 'github-light-default' | 'github-light-high-contrast' | 'houston' | 'kanagawa-dragon' | 'kanagawa-lotus' | 'kanagawa-wave' | 'laserwave' | 'light-plus' | 'material-theme' | 'material-theme-darker' | 'material-theme-lighter' | 'material-theme-ocean' | 'material-theme-palenight' | 'min-dark' | 'min-light' | 'monokai' | 'night-owl' | 'nord' | 'one-dark-pro' | 'one-light' | 'plastic' | 'poimandres' | 'red' | 'rose-pine' | 'rose-pine-dawn' | 'rose-pine-moon' | 'slack-dark' | 'slack-ochin' | 'snazzy-light' | 'solarized-dark' | 'solarized-light' | 'synthwave-84' | 'tokyo-night' | 'vesper' | 'vitesse-black' | 'vitesse-dark' | 'vitesse-light'
      dark: 'ayu-dark'
    }
  },
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/images/favicon.svg' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    ['link', { href: 'https://fonts.googleapis.com/css2?family=Jersey+10&display=swap', rel: 'stylesheet' }]
  ],
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config

    siteTitle: '🌵Tecs',

    nav: [
      { text: 'Guide', link: '/guide/quickstart' },
      { text: 'Reference', link: '/reference/' }
    ],

    sidebar: [
      {
        text: 'Tecs Guide',
        items: [
          { text: 'ECS quickstart', link: '/guide/quickstart' },
          { text: 'Install and setup', link: '/guide/install' },
        ]
      },
      {
        text: 'Tecs Reference',
        collapsed: true,
        items: [
          { text: 'Tecs API', link: '/reference/' },
          { text: 'World', link: '/reference/world' },
          { text: 'Phases', link: '/reference/phases' },
          { text: 'Systems', link: '/reference/systems' },
          { text: 'Queries', link: '/reference/queries' },
          { text: 'Components', link: '/reference/components' },
          { text: 'FFI Components', link: '/reference/ffi-components' },
          { text: 'Relationships', link: '/reference/relationships' },
          { text: 'Archetypes', link: '/reference/archetype' },
          { text: 'Events', link: '/reference/events' },
          { text: 'States', link: '/reference/states' },
          { text: 'Builtins', link: '/reference/builtins' },
          { text: 'Logging', link: '/reference/logging' },
        ]
      },
      {
        text: 'Tecs2D',
        collapsed: true,
        items: [
          { text: 'Tecs2D API', link: '/tecs2d/' },
          { text: 'Input handling', link: '/tecs2d/input-handling' },
          { text: 'Love2D events', link: '/tecs2d/events' },
          { text: 'Stats', link: '/tecs2d/stats' }
        ]
      },
      {
        text: 'Plugins',
        collapsed: true,
        items: [
          { text: '📦 Assets', link: '/plugins/tecs_assets' },
          { text: '🎮 Controller', link: '/plugins/tecs_controller' },
          { text: '🎬 Render', link: '/plugins/tecs_render' },
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/mtdowling/tecs' }
    ],

    footer: {
      message: 'Released under the <a href="https://github.com/mtdowling/tecs/blob/main/LICENSE">MIT License</a>.',
      copyright: 'Copyright © <a href="https://github.com/mtdowling">Michael Dowling</a>'
    }
  }
}))
