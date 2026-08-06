// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'VibeCare Docs',
      description: 'Documentation for the VibeCare wellness & routine platform.',
      sidebar: [
        {
          label: 'Overview',
          items: [
            { label: 'Documentation Index', link: '/readme/' },
            { label: 'Architecture', link: '/architecture/' },
            { label: 'Architecture (Deep Dive)', link: '/arch/' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Local Build', link: '/local_build/' },
            { label: 'Release Process', link: '/release_process/' },
            { label: 'Signing Setup', link: '/signing_setup/' },
            { label: 'macOS Debug Pkg', link: '/macos/debug_mac_pkg/' },
          ],
        },
        {
          label: 'MCP',
          items: [
            { label: 'MCP Setup', link: '/mcp_setup/' },
            { label: 'MCP Implementation Status', link: '/mcp_implementation_status/' },
          ],
        },
        {
          label: 'Actions',
          items: [
            { label: 'Actions Implementation', link: '/actions_implementation/' },
            { label: 'Cross-Platform System Commands', link: '/cross-platform-system-commands/' },
          ],
        },
        {
          label: 'Plugin System',
          items: [
            { label: 'Architecture Findings', link: '/plugin-architecture-findings/' },
            { label: 'Decisions', link: '/plugin-system-decisions/' },
          ],
        },
        {
          label: 'Notes',
          collapsed: true,
          items: [
            { label: 'Backlog', link: '/backlog/' },
            { label: 'Braindump', link: '/braindump/' },
            { label: 'Ideas', link: '/ideas/' },
            { label: 'Init', link: '/init/' },
          ],
        },
        { label: 'Specs', collapsed: true, autogenerate: { directory: 'superpowers/specs' } },
        { label: 'Plans', collapsed: true, autogenerate: { directory: 'superpowers/plans' } },
      ],
    }),
  ],
});
