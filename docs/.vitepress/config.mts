import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";
// Local Teal TextMate grammar (teal-language/vscode-teal). Bundled into the
// build; registering it here adds `teal`/`tl` highlighting with no upstream PR.
import tealGrammar from "./teal.tmLanguage.json";

// Map a page's source path to the generated LLM-friendly Markdown URL.
// "ecs/index.md" -> "/ecs.md", "ecs/world.md" -> "/ecs/world.md".
// Returns null for the site homepage (no per-page Markdown is emitted).
function mdSourceUrl(relativePath: string): string | null {
    if (relativePath === "index.md") return null;
    const clean = relativePath
        .replace(/(^|\/)index\.md$/, "$1")
        .replace(/\.md$/, "")
        .replace(/\/$/, "");
    return `/${clean}.md`;
}

// https://vitepress.dev/reference/site-config
export default defineConfig({
    title: "Tecs",
    description: "Typed entity component system and game engine for Lua.",
    vite: {
        plugins: [
            llmstxt({
                description: "Typed entity component system and game engine for Lua.",
                details:
                    "Tecs is a typed entity component system for LuaJIT and the game engine built " +
                    "around it, written in Teal. The ECS knows what the GPU reads, so rendering is not a " +
                    "layer bolted on top of a renderer-agnostic core. SDL owns the loop: an entry file " +
                    "returns an application and a C host drives it.",
            }),
        ],
    },
    markdown: {
        theme: {
            light: "github-light-high-contrast",
            dark: "tokyo-night",
        },
        languages: [{ ...(tealGrammar as any), name: "teal", aliases: ["tl"] }],
    },
    head: [
        ["link", { rel: "icon", type: "image/svg+xml", href: "/images/logo.svg" }],
        ["link", { rel: "preconnect", href: "https://fonts.googleapis.com" }],
        ["link", { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "" }],
        ["link", { href: "https://fonts.googleapis.com/css2?family=Jersey+15&display=swap", rel: "stylesheet" }],
    ],
    // Advertise the LLM-friendly Markdown source of each page.
    transformHead({ pageData }) {
        const href = mdSourceUrl(pageData.relativePath);
        if (!href) return;
        return [["link", { rel: "alternate", type: "text/markdown", href }]];
    },
    themeConfig: {
        // https://vitepress.dev/reference/default-theme-config

        siteTitle: "Tecs",

        search: {
            provider: "local",
        },

        nav: [
            { text: "Get started", link: "/getting-started" },
            { text: "Modules", link: "/modules/" },
            { text: "tecs.ecs", link: "/ecs/" },
            { text: "CLI", link: "/cli/" },
        ],

        sidebar: [
            {
                text: "Introduction",
                collapsed: false,
                items: [
                    { text: "Getting started", link: "/getting-started" },
                    { text: "Modules", link: "/modules/" },
                    { text: "Tecs CLI", link: "/cli/" },
                ],
            },
            // One row per page, and no row for anything smaller. The sidebar
            // moves a reader between pages; a function lives on the page that
            // documents it and is reached by scrolling or through the outline
            // VitePress renders from that page's own headings. Three rows that
            // land in the same place teach a reader that the sidebar does not
            // know where things are.
            //
            // Alphabetical ignoring case, and spelled the way a game writes it.
            // A reader looking for `tecs.filesystem.watch` scans for that string; a
            // thematic grouping makes them guess which of four headings
            // somebody filed it under first, and a collapsed group hides the
            // name entirely until they guess right.
            //
            // The one nesting is the real one. A module that sits inside
            // another module is a row inside its parent's group, because that
            // is where its name puts it: a reader holding `tecs.gfx.layers`
            // reads it left to right and finds `tecs.gfx` first. The group is
            // open, so nothing is hidden behind a guess, and it is not a theme
            // somebody invented: the parent is a name a game writes.
            //
            // `tecs.ecs` is the group below rather than a row here, and
            // `tecs.version` is a string with no page of its own; both are in
            // the index, which is the list of names.
            {
                text: "Modules",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/modules/" },
                    { text: "Generated signatures", link: "/modules/" },
                    { text: "tecs.application", link: "/modules/application" },
                    { text: "tecs.assets", link: "/modules/assets" },
                    { text: "tecs.audio", link: "/modules/audio" },
                    { text: "tecs.data", link: "/modules/data" },
                    { text: "tecs.events", link: "/modules/events" },
                    {
                        text: "tecs.filesystem",
                        collapsed: false,
                        items: [
                            { text: "Overview", link: "/modules/filesystem/" },
                            { text: "tecs.filesystem.watch", link: "/modules/filesystem/watch" },
                        ],
                    },
                    { text: "tecs.future", link: "/modules/future" },
                    {
                        text: "tecs.gfx",
                        collapsed: false,
                        items: [
                            { text: "Overview", link: "/modules/gfx/" },
                            { text: "tecs.gfx.animation", link: "/modules/gfx/animation" },
                            { text: "tecs.gfx.layers", link: "/modules/gfx/layers" },
                            { text: "tecs.gfx.materials", link: "/modules/gfx/materials" },
                            { text: "tecs.gfx.particles", link: "/modules/gfx/particles" },
                        ],
                    },
                    { text: "tecs.http", link: "/modules/http" },
                    { text: "tecs.input", link: "/modules/input" },
                    { text: "tecs.log", link: "/modules/log" },
                    { text: "tecs.mcp", link: "/modules/mcp" },
                    { text: "tecs.net", link: "/modules/net" },
                    { text: "tecs.physics", link: "/modules/physics" },
                    { text: "tecs.sequence", link: "/modules/sequence" },
                    { text: "tecs.system", link: "/modules/system" },
                    { text: "tecs.time", link: "/modules/time" },
                    { text: "tecs.window", link: "/modules/window" },
                    { text: "tecs.workers", link: "/modules/workers" },
                ],
            },
            // The concept pages, under the module that holds the ECS rather
            // than under an invented category. `tecs.ecs` is one table: an
            // engine module requires it, a game reads it off `tecs`, and both
            // reach what is listed here.
            //
            // Alphabetical, with each section's own overview first.
            {
                text: "tecs.ecs",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/ecs/" },
                    { text: "Archetypes", link: "/ecs/archetype" },
                    { text: "Builtins", link: "/ecs/builtins" },
                    {
                        text: "Components",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/components/" },
                            { text: "Bundles", link: "/ecs/components/bundles" },
                            { text: "Construction", link: "/ecs/components/construction" },
                            { text: "Dirty tracking", link: "/ecs/components/dirty-tracking" },
                            { text: "FFI components", link: "/ecs/components/ffi" },
                            { text: "Scalar components", link: "/ecs/components/scalar-components" },
                            { text: "Serialization", link: "/ecs/components/serialization" },
                            { text: "Table components", link: "/ecs/components/table-components" },
                            { text: "Tag components", link: "/ecs/components/tag-components" },
                        ],
                    },
                    { text: "Events", link: "/ecs/events" },
                    { text: "Mutation model", link: "/ecs/mutation-model" },
                    { text: "Phases", link: "/ecs/phases" },
                    { text: "Plugins", link: "/ecs/plugins" },
                    { text: "Profiling", link: "/ecs/profiling" },
                    {
                        text: "Queries",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/queries/" },
                            { text: "Callbacks", link: "/ecs/queries/callbacks" },
                            { text: "Grouping", link: "/ecs/queries/grouping" },
                        ],
                    },
                    { text: "Random", link: "/ecs/random" },
                    {
                        text: "Relationships",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/relationships/" },
                            { text: "FFI relationships", link: "/ecs/relationships/ffi" },
                        ],
                    },
                    { text: "Save games", link: "/ecs/save-games" },
                    { text: "States", link: "/ecs/states" },
                    { text: "Systems", link: "/ecs/systems" },
                    { text: "World", link: "/ecs/world" },
                ],
            },
        ],

        socialLinks: [{ icon: "github", link: "https://github.com/tecs-dev/tecs" }],

        footer: {
            message:
                'Tecs code is released under the <a href="https://github.com/tecs-dev/tecs/blob/main/LICENSE-MIT">MIT</a> ' +
                'or <a href="https://github.com/tecs-dev/tecs/blob/main/LICENSE-APACHE">Apache-2.0</a> license, at your option. ' +
                '<a href="https://github.com/tecs-dev/tecs/blob/main/THIRD_PARTY_NOTICES.md">Third-party notices</a>. ' +
                'For LLMs: <a href="/llms.txt">llms.txt</a> · <a href="/llms-full.txt">llms-full.txt</a>.',
            copyright: 'Copyright © <a href="https://github.com/mtdowling">Michael Dowling</a>',
        },
    },
});
