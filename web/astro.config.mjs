// 세컨드 브레인 홍보 페이지 (설계서 3.1): 정적 사이트. 앱 기능·지식 데이터는 다루지 않는다.
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  output: 'static',
  vite: { plugins: [tailwindcss()] },
});
