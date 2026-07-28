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
            { text: "ECS", link: "/ecs/" },
            { text: "Modules", link: "/modules/" },
            { text: "CLI", link: "/cli/" },
        ],

        sidebar: [
            {
                text: "Introduction",
                collapsed: false,
                items: [
                    { text: "Getting started", link: "/getting-started" },
                    { text: "Module reference", link: "/modules/" },
                    { text: "The CLI", link: "/cli/" },
                ],
            },
            {
                text: "The ECS",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/ecs/" },
                    { text: "World", link: "/ecs/world" },
                    { text: "Phases", link: "/ecs/phases" },
                    { text: "Systems", link: "/ecs/systems" },
                    { text: "Plugins", link: "/ecs/plugins" },
                    {
                        text: "Queries",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/queries/" },
                            { text: "Callbacks", link: "/ecs/queries/callbacks" },
                            { text: "Grouping", link: "/ecs/queries/grouping" },
                        ],
                    },
                    {
                        text: "Components",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/components/" },
                            { text: "Construction", link: "/ecs/components/construction" },
                            { text: "Table components", link: "/ecs/components/table-components" },
                            { text: "Tag components", link: "/ecs/components/tag-components" },
                            { text: "Scalar components", link: "/ecs/components/scalar-components" },
                            { text: "FFI components", link: "/ecs/components/ffi" },
                            { text: "Bundles", link: "/ecs/components/bundles" },
                            { text: "Serialization", link: "/ecs/components/serialization" },
                            { text: "Dirty tracking", link: "/ecs/components/dirty-tracking" },
                        ],
                    },
                    {
                        text: "Relationships",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/relationships/" },
                            { text: "FFI relationships", link: "/ecs/relationships/ffi" },
                        ],
                    },
                    { text: "Archetypes", link: "/ecs/archetype" },
                    { text: "Events", link: "/ecs/events" },
                    { text: "States", link: "/ecs/states" },
                    { text: "Builtins", link: "/ecs/builtins" },
                    { text: "Save games", link: "/ecs/save-games" },
                    { text: "Profiling", link: "/ecs/profiling" },
                    { text: "Mutation model", link: "/ecs/mutation-model" },
                ],
            },
            {
                text: "Modules",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/modules/" },
                    {
                        text: "Lifecycle and rendering",
                        collapsed: true,
                        items: [
                            { text: "Application", link: "/modules/Application" },
                            { text: "Renderer", link: "/modules/Renderer" },
                            { text: "Camera", link: "/modules/Camera" },
                            { text: "layers", link: "/modules/layers" },
                            { text: "materials", link: "/modules/materials" },
                            { text: "sheet", link: "/modules/sheet" },
                            { text: "animation", link: "/modules/animation" },
                            { text: "text", link: "/modules/text" },
                            { text: "particles", link: "/modules/particles" },
                            { text: "components", link: "/modules/components" },
                        ],
                    },
                    {
                        text: "Platform",
                        collapsed: true,
                        items: [
                            { text: "Window", link: "/modules/Window" },
                            { text: "Input", link: "/modules/Input" },
                            { text: "Gamepad", link: "/modules/Gamepad" },
                            { text: "events", link: "/modules/events" },
                            { text: "clock", link: "/modules/clock" },
                            { text: "clipboard", link: "/modules/clipboard" },
                            { text: "proc", link: "/modules/proc" },
                            { text: "paths", link: "/modules/paths" },
                            { text: "filesystem", link: "/modules/filesystem" },
                            { text: "watch", link: "/modules/watch" },
                            { text: "capabilities", link: "/modules/capabilities" },
                        ],
                    },
                    {
                        text: "Simulation and content",
                        collapsed: true,
                        items: [
                            { text: "physics", link: "/modules/physics" },
                            { text: "Audio", link: "/modules/Audio" },
                            { text: "sequence", link: "/modules/sequence" },
                            { text: "assets", link: "/modules/assets" },
                            { text: "workers", link: "/modules/workers" },
                            { text: "Future", link: "/modules/Future" },
                        ],
                    },
                    {
                        text: "Tooling and utilities",
                        collapsed: true,
                        items: [
                            { text: "log", link: "/modules/log" },
                            { text: "mcp", link: "/modules/mcp" },
                            { text: "json", link: "/modules/json" },
                            { text: "hash", link: "/modules/hash" },
                            { text: "compress", link: "/modules/compress" },
                            { text: "random", link: "/modules/random" },
                        ],
                    },
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
