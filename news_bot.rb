# frozen_string_literal: true

require "rss"
require "open-uri"
require "json"
require "http"
require "time"
require "cgi"

JST = "+09:00"

RSS_URLS = [
  "https://news.google.com/rss/search?q=AI+人工知能&hl=ja&gl=JP&ceid=JP:ja",
  "https://news.google.com/rss/search?q=AI+machine+learning&hl=en-US&gl=US&ceid=US:en",
  "https://techcrunch.com/tag/artificial-intelligence/feed/",
  "https://venturebeat.com/category/ai/feed/"
]

KEYWORDS = %w[OpenAI Google Anthropic LLM GPT Gemini Claude Meta Microsoft].freeze

# =========================================
# Time Window (JST stateless)
# =========================================
def day_window_jst
  now = Time.now.getlocal(JST)
  today_midnight = Time.new(now.year, now.month, now.day, 0, 0, 0, JST)
  yesterday_midnight = today_midnight - 86_400
  [yesterday_midnight, today_midnight]
end

# =========================================
# RSS Fetch
# =========================================
def extract_summary(item, max_length: 200)
  raw = item.respond_to?(:description) ? item.description.to_s : ""
  text = CGI.unescapeHTML(raw.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip)
  return "" if text.empty?

  text.length > max_length ? "#{text[0...max_length]}..." : text
end

def fetch_articles(urls, from_time, to_time)
  articles = []

  urls.each do |url|
    begin
      rss = RSS::Parser.parse(URI.open(url).read, false)
    rescue => e
      warn "[RSS ERROR] #{url} #{e.message}"
      next
    end

    rss.items.each do |item|
      next unless item.respond_to?(:pubDate) && item.pubDate

      pub_time = Time.parse(item.pubDate.to_s).getlocal(JST)
      next unless pub_time >= from_time && pub_time < to_time

      articles << {
        title: item.title.to_s.strip,
        link: item.link.to_s,
        summary: extract_summary(item),
        published: pub_time
      }
    rescue
      next
    end
  end

  articles
end

# =========================================
# Deduplication
# =========================================
def normalize_title(text)
  text.to_s.downcase.gsub(/[^a-z0-9ぁ-んァ-ン一-龥]/, "")
end

def deduplicate_articles(articles)
  seen = {}
  articles.reject do |article|
    key = normalize_title(article[:title])
    seen[key] ? true : (seen[key] = true; false)
  end
end

# =========================================
# Scoring
# =========================================
def add_scores(articles)
  articles.each do |article|
    article[:score] = KEYWORDS.count { |k| article[:title].include?(k) }
  end
end

def pick_top_articles(articles, limit: 10)
  articles.sort_by { |a| -a[:score] }.first(limit)
end

# =========================================
# Gemini Common Caller
# =========================================
def call_gemini(prompt)
  api_key = ENV["GEMINI_API_KEY"]
  raise "GEMINI_API_KEY missing" if api_key.to_s.empty?

  response = HTTP.post(
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=#{api_key}",
    json: {
      contents: [{ parts: [{ text: prompt }] }]
    }
  )

  result = JSON.parse(response.body.to_s)
  result.dig("candidates", 0, "content", "parts", 0, "text").to_s
rescue => e
  warn "[Gemini ERROR] #{e.message}"
  ""
end

# =========================================
# Gemini: 意味重複排除 + 5件選定
# =========================================
def build_selection_prompt(articles)
  <<~TEXT
    以下のニュースタイトルがあります。
    内容が実質同じニュースは1つにまとめ、
    重要なものを5件選び、
    JSON配列のみで返してください。

    [
      {"title": "..."}
    ]

    #{articles.map { |a| "- #{a[:title]}" }.join("\n")}
  TEXT
end

def gemini_select(articles)
  raw = call_gemini(build_selection_prompt(articles))

  json_text = raw[/\[[\s\S]*\]/]
  JSON.parse(json_text)
rescue
  articles.first(5).map { |a| { "title" => a[:title] } }
end

def resolve_selected_articles(selected, candidates)
  selected.map do |sel|
    candidates.find { |a| a[:title] == sel["title"] }
  end.compact
end

# =========================================
# Gemini: 要約生成
# =========================================
def build_summary_prompt(article)
  <<~TEXT
    次のニュースを日本語で140字以内で要約してください。
    本文のみ出力してください。

    タイトル:
    #{article[:title]}

    補足:
    #{article[:summary]}
  TEXT
end

def generate_summary(article)
  summary = call_gemini(build_summary_prompt(article)).strip
  summary.empty? ? article[:summary] : summary
end

# =========================================
# Slack Output
# =========================================
def build_slack_text(article)
  [
    "*#{article[:title]}*",
    article[:summary],
    "<#{article[:link]}|続きを読む>"
  ].reject(&:empty?).join("\n")
end

def build_slack_blocks(articles)
  articles.map do |article|
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: build_slack_text(article)
      }
    }
  end
end

def post_to_slack(articles)
  webhook = ENV["SLACK_WEBHOOK_URL"]
  raise "SLACK_WEBHOOK_URL missing" if webhook.to_s.empty?

  blocks = build_slack_blocks(articles)
  HTTP.post(webhook, json: { blocks: blocks })
end

# =========================================
# Orchestration
# =========================================
def run
  from_time, to_time = day_window_jst

  articles = fetch_articles(RSS_URLS, from_time, to_time)
  articles = deduplicate_articles(articles)

  add_scores(articles)
  top_articles = pick_top_articles(articles, limit: 10)

  selected = gemini_select(top_articles)
  final_articles = resolve_selected_articles(selected, top_articles)

  # 要約生成
  final_articles.each do |article|
    article[:summary] = generate_summary(article)
  end

  post_to_slack(final_articles)
end

run
