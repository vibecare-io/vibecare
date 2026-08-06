// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  integrations: [
    starlight({
      title: 'VibeCare Docs',
      description: 'Documentation for the VibeCare wellness & routine platform.',
      sidebar: [
        { label: 'Docs', autogenerate: { directory: '.' } },
      ],
    }),
  ],
});
