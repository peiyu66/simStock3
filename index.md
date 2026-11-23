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

{% assign body = readme | remove_first: readme_heading %}
{% comment %}
  Pages' relative-links generator runs before Liquid expands includes. Resolve the
  README's documentation links here against the same actual Jekyll page targets.
{% endcomment %}
{%- assign targets = site.pages | concat: site.static_files -%}
{%- for target in targets -%}
  {%- assign path = target.path -%}
  {%- assign first_character = path | slice: 0, 1 -%}
  {%- if first_character == "/" -%}{%- assign path = path | remove_first: "/" -%}{%- endif -%}
  {%- assign folder = path | slice: 0, 4 -%}
  {%- assign suffix = path | slice: -3, 3 -%}
  {%- if folder == "doc/" and suffix == ".md" -%}
    {%- assign token = "](" | append: path -%}
    {%- if body contains token -%}
      {%- assign href = target.url | relative_url -%}
      {%- assign old_link = token | append: ")" -%}
      {%- assign new_link = "](" | append: href | append: ")" -%}
      {%- assign old_anchor = token | append: "#" -%}
      {%- assign new_anchor = "](" | append: href | append: "#" -%}
      {%- assign body = body | replace: old_link, new_link | replace: old_anchor, new_anchor -%}
    {%- endif -%}
  {%- endif -%}
{%- endfor -%}
{{ body }}
