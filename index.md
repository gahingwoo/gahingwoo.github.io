---
layout: page
title: My Projects
---

# 🚀 Welcome to My GitHub Projects!

Hey there! 👋 You’ve just landed in my **little coding playground**.  
Think of this page as my personal tech zoo 🦁🐒🐢 — every repo is a different animal,  
some are cute experiments, some are wild side projects, and a few might actually be useful. 😏  

Here’s the treasure map 🗺️ to all my public repositories.  
Feel free to click around — you never know what you’ll discover! ✨

---

<ul>
{% for repo in site.github.public_repositories %}
  <li>
    <strong><a href="{{ repo.html_url }}" target="_blank">🎯 {{ repo.name | replace: "-", " " }}</a></strong>
    {% if repo.description %}
      <br>👉 {{ repo.description }}
    {% endif %}
    {% if repo.language or repo.stargazers_count %}
      <br>
      {% if repo.language %}💻 Language: {{ repo.language }}{% endif %}
      {% if repo.stargazers_count %} ⭐ Stars: {{ repo.stargazers_count }}{% endif %}
    {% endif %}
    <br><br>
  </li>
{% endfor %}
</ul>

---

💡 Pro tip: If you like something here, drop a ⭐ — it makes my day brighter than `printf("Hello World!");` 🌞  
