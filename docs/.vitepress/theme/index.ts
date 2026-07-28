// https://vitepress.dev/guide/custom-theme
import { h } from "vue";
import type { Theme } from "vitepress";
import DefaultTheme from "vitepress/theme";
import NavMarkdownLink from "./NavMarkdownLink.vue";
import "./style.css";

export default {
    extends: DefaultTheme,
    Layout: () => {
        return h(DefaultTheme.Layout, null, {
            // https://vitepress.dev/guide/extending-default-theme#layout-slots
            "nav-bar-content-after": () => h(NavMarkdownLink),
        });
    },
    enhanceApp({ app, router, siteData }) {
        // ...
    },
} satisfies Theme;
