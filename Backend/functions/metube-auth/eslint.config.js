import js from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";
import oxlint from "eslint-plugin-oxlint";

export default tseslint.config(
  { ignores: ["dist"] },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ["**/*.{ts,tsx}"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: globals.node,
    },
  },
  oxlint.configs["flat/recommended"],
);
