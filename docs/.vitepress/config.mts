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
        // A page is compiled as a Vue template, so `{{ ... }}` inside inline
        // code is read as an interpolation and rendered as whatever the
        // expression evaluates to, which for a type like `{{string, string}}`
        // is nothing. Fenced blocks are already given `v-pre`; inline code is
        // not, and a signature that quietly loses an argument is exactly the
        // kind of confidently wrong reference this site is meant not to carry.
        config(md) {
            const renderInline = md.renderer.rules.code_inline;
            md.renderer.rules.code_inline = (tokens, index, options, env, self) => {
                tokens[index].attrSet("v-pre", "");
                return renderInline
                    ? renderInline(tokens, index, options, env, self)
                    : self.renderToken(tokens, index, options);
            };
        },
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
            { text: "Surface", link: "/modules/" },
            { text: "CLI", link: "/cli/" },
        ],

        sidebar: [
            {
                text: "Introduction",
                collapsed: false,
                items: [
                    { text: "Getting started", link: "/getting-started" },
                    { text: "The surface", link: "/modules/" },
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
            // Flat, and spelled the way a game writes it. A reader looking for
            // `tecs.watch` scans for that string; a taxonomy makes them guess
            // which of four groups somebody filed it under first, and a
            // collapsed group hides the name entirely until they guess right.
            // The order matches docs/modules/index.md so the two read alike.
            {
                text: "The surface",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/modules/" },
                    { text: "Generated signatures", link: "/modules/surface" },
                    { text: "tecs.Application", link: "/modules/Application" },
                    { text: "tecs.Renderer", link: "/modules/Renderer" },
                    { text: "tecs.Camera", link: "/modules/Camera" },
                    { text: "tecs.layers", link: "/modules/layers" },
                    { text: "tecs.materials", link: "/modules/materials" },
                    { text: "tecs.sheet", link: "/modules/sheet" },
                    { text: "tecs.animation", link: "/modules/animation" },
                    { text: "tecs.text", link: "/modules/text" },
                    { text: "tecs.particles", link: "/modules/particles" },
                    { text: "tecs.components", link: "/modules/components" },
                    { text: "tecs.Window", link: "/modules/Window" },
                    { text: "tecs.Input", link: "/modules/Input" },
                    { text: "tecs.Gamepad", link: "/modules/Gamepad" },
                    { text: "tecs.events", link: "/modules/events" },
                    { text: "tecs.clock", link: "/modules/clock" },
                    { text: "tecs.clipboard", link: "/modules/clipboard" },
                    { text: "tecs.proc", link: "/modules/proc" },
                    { text: "tecs.paths", link: "/modules/paths" },
                    { text: "tecs.filesystem", link: "/modules/filesystem" },
                    { text: "tecs.watch", link: "/modules/watch" },
                    { text: "tecs.capabilities", link: "/modules/capabilities" },
                    { text: "tecs.physics", link: "/modules/physics" },
                    { text: "tecs.Audio", link: "/modules/Audio" },
                    { text: "tecs.sequence", link: "/modules/sequence" },
                    { text: "tecs.assets", link: "/modules/assets" },
                    { text: "tecs.workers", link: "/modules/workers" },
                    { text: "tecs.Future", link: "/modules/Future" },
                    { text: "tecs.log", link: "/modules/log" },
                    { text: "tecs.mcp", link: "/modules/mcp" },
                    { text: "tecs.json", link: "/modules/json" },
                    { text: "tecs.hash", link: "/modules/hash" },
                    { text: "tecs.compress", link: "/modules/compress" },
                    { text: "tecs.random", link: "/modules/random" },
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
