const path = require("path");

module.exports = {
  presets: [require("@novasoftwarefoundation/prism/tailwind.preset")],
  content: [path.join(__dirname, "../priv/static/index.html"), path.join(__dirname, "../priv/static/app.js")],
};
