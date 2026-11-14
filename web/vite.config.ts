import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  // a hosted build ships no public/ (local.json holds the anvil dev key)
  publicDir: process.env.VITE_HOSTED === "1" ? false : "public",
  server: { fs: { allow: [".."] } }, // the contract ABI comes from ../out
});
