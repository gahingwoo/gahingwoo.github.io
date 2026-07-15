/* global hexo */
'use strict';

// hexo-generator-feed writes raw XML with no styling. Wrap its generator to
// attach feed.xsl, which renders a readable preview in browsers that still
// support client-side XSLT (Firefox, Safari; Chrome dropped it) instead of a
// wall of tags. Feed readers get plain, valid XML either way — the main fix
// for "clicking RSS just shows code" is the /subscribe/ page instead.
//
// Patching the output file in an `after_generate` filter doesn't work here:
// that filter fires before Hexo flushes generated routes like atom.xml to
// disk, so the file doesn't exist yet at that point. Wrapping the generator
// itself intercepts the content before it ever becomes a route.
const feedConfig = hexo.config.feed || {};
let feedTypes = feedConfig.type || 'atom';
if (!Array.isArray(feedTypes)) {
  feedTypes = [feedTypes];
}

feedTypes.forEach(function (type) {
  const original = hexo.extend.generator.get(type);
  if (!original) {
    return;
  }
  hexo.extend.generator.register(type, function (locals) {
    return original.call(this, locals).then(function (result) {
      if (result && typeof result.data === 'string' && !result.data.includes('xml-stylesheet')) {
        result.data = result.data.replace(
          /^(<\?xml[^>]*\?>)/,
          '$1\n<?xml-stylesheet type="text/xsl" href="/feed.xsl"?>'
        );
      }
      return result;
    });
  });
});
