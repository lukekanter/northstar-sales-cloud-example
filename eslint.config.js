const { defineConfig } = require("eslint/config");
const eslintJs = require("@eslint/js");
const jestPlugin = require("eslint-plugin-jest");
const auraConfig = require("@salesforce/eslint-plugin-aura");
const lwcConfig = require("@salesforce/eslint-config-lwc/recommended");
const globals = require("globals");

module.exports = defineConfig([
  // Vendored Quicker Quotes accelerator: copied from
  // SalesforceLabs/Quicker-Quotes @ d1c406e under BSD 3-Clause and kept as-is
  // (no upstream logic changes), so the vendor LWC/aura JS is exempt from the
  // Northstar lint rules. Northstar-authored components are still linted.
  {
    // Gitignored raw accelerator clones — never our code to lint.
    ignores: ["vendor/**"]
  },

  // Aura configuration
  {
    files: ["**/aura/**/*.js"],
    extends: [...auraConfig.configs.recommended, ...auraConfig.configs.locker]
  },

  // LWC configuration
  {
    files: ["**/lwc/**/*.js"],
    extends: [lwcConfig]
  },

  // LWC configuration with override for LWC test files
  {
    files: ["**/lwc/**/*.test.js"],
    extends: [lwcConfig],
    rules: {
      "@lwc/lwc/no-unexpected-wire-adapter-usages": "off"
    },
    languageOptions: {
      globals: {
        ...globals.node
      }
    }
  },

  // Jest mocks configuration
  {
    files: ["**/jest-mocks/**/*.js"],
    languageOptions: {
      sourceType: "module",
      ecmaVersion: "latest",
      globals: {
        ...globals.node,
        ...globals.es2021,
        ...jestPlugin.environments.globals.globals
      }
    },
    plugins: {
      eslintJs
    },
    extends: ["eslintJs/recommended"]
  },

  // Vendored Quicker Quotes accelerator: copied from
  // SalesforceLabs/Quicker-Quotes @ d1c406e under BSD 3-Clause and kept as-is
  // (no upstream logic changes). This block must stay AFTER the lwc/aura base
  // configs so it overrides them: the vendor's own style (loose equality,
  // @api reassignments, debounce setTimeout, etc.) is exempt from the
  // Northstar lint rules. Northstar-authored components remain fully linted.
  {
    files: [
      "force-app/main/default/lwc/qqProductsTable/**/*.js",
      "force-app/main/default/lwc/qqProductsSearchModal/**/*.js",
      "force-app/main/default/aura/QQ_GlobalAction/**/*.js",
      "force-app/main/default/aura/QQ_NavigateToRecord/**/*.js"
    ],
    // The aura locker preset pins an old ECMA version under which `const`/
    // `let` parse-error; the vendor controllers use them and deploy fine, so
    // raise the parser version for these files only.
    languageOptions: {
      ecmaVersion: 2021
    },
    rules: {
      "@lwc/lwc/no-api-reassignments": "off",
      "@lwc/lwc/no-async-operation": "off",
      eqeqeq: "off",
      "no-unused-expressions": "off",
      "no-unused-vars": "off",
      radix: "off",
      "vars-on-top": "off"
    }
  }
]);
