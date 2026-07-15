<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:atom="http://www.w3.org/2005/Atom">
<xsl:output method="html" encoding="UTF-8" indent="yes"/>
<xsl:template match="/atom:feed">
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title><xsl:value-of select="atom:title"/> &#8212; RSS Feed</title>
<style>
  body { max-width: 720px; margin: 2.5em auto; padding: 0 1.25em; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; color: #1f2430; background: #fff; line-height: 1.5; }
  a { color: #3273dc; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .notice { background: #f7f7fb; border: 1px solid #e5e5ec; border-radius: 8px; padding: 1em 1.25em; margin-bottom: 2em; font-size: 0.95em; color: #444; }
  .notice code { background: #eceef3; padding: 0.1em 0.4em; border-radius: 4px; }
  h1 { font-size: 1.6em; margin-bottom: 0.2em; }
  .subtitle { color: #666; margin-top: 0; margin-bottom: 1.5em; }
  .entry { padding: 1.1em 0; border-bottom: 1px solid #eee; }
  .entry:last-child { border-bottom: none; }
  .entry h2 { font-size: 1.15em; margin: 0 0 0.3em; }
  .entry time { color: #888; font-size: 0.85em; }
  .entry p { margin: 0.5em 0 0; color: #333; }
  @media (prefers-color-scheme: dark) {
    body { background: #16181d; color: #dcdde2; }
    .notice { background: #1f232b; border-color: #2a2f3a; color: #b8bcc4; }
    .notice code { background: #2a2f3a; }
    .entry { border-color: #2a2f3a; }
    .entry p { color: #c2c5cc; }
    .subtitle, .entry time { color: #8a8f99; }
  }
</style>
</head>
<body>
  <p class="notice">
    This is an RSS/Atom feed, not a regular web page &#8212; you're seeing this
    preview because your browser opened it directly. To get new posts
    automatically, copy this page's URL into a feed reader (e.g. Feedly,
    Inoreader, NetNewsWire) rather than visiting it here: <br/>
    <code><xsl:value-of select="atom:link[@rel='self']/@href"/></code>
  </p>
  <h1><xsl:value-of select="atom:title"/></h1>
  <p class="subtitle"><xsl:value-of select="atom:subtitle"/></p>
  <xsl:for-each select="atom:entry">
    <div class="entry">
      <h2><a href="{atom:link/@href}"><xsl:value-of select="atom:title"/></a></h2>
      <time><xsl:value-of select="substring(atom:published, 1, 10)"/></time>
      <p><xsl:value-of select="atom:summary"/></p>
    </div>
  </xsl:for-each>
</body>
</html>
</xsl:template>
</xsl:stylesheet>
