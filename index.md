---
layout: default
title: simStock3
lang: zh-Hant
---
{% capture readme %}{% include_relative README.md %}{% endcapture %}
{% capture newline %}
{% endcapture %}
{% assign readme_heading = readme | strip | split: newline | first %}
{% assign app_title = readme_heading | remove_first: '# ' %}

<div style="display: flex; align-items: center; gap: 1.1rem; margin-bottom: 1rem;">
  <img src="app-icon.png" width="64" height="64" alt="" style="flex: 0 0 4rem; border-radius: .95rem;">
  <h1 style="margin: 0; min-width: 0;">{{ app_title | escape }}</h1>
</div>

{{ readme | remove_first: readme_heading }}
