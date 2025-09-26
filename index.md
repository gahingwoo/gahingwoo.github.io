---
layout: page
title: My Projects
---

# My GitHub Projects

Welcome to my GitHub project homepage. Below is a list of all my public repositories:

<ul>
{% for repo in site.github.public_repositories %}
  <li>
    <strong><a href="{{ repo.html_url }}" target="_blank">{{ repo.name | replace: "-", " " }}</a></strong>
    {% if repo.description %}
      <br>{{ repo.description }}
    {% endif %}
    {% if repo.language or repo.stargazers_count %}
      <br>
      {% if repo.language %}Language: {{ repo.language }}{% endif %}
      {% if repo.stargazers_count %} ⭐ {{ repo.stargazers_count }}{% endif %}
    {% endif %}
  </li>
{% endfor %}
</ul>