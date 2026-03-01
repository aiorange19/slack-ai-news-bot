# frozen_string_literal: true

require "rss"
require "json"
require "http"
require "time"
require "cgi"
require "uri"

TIME_ZONE = "Asia/Tokyo"
JST = "+09:00"

RSS_URLS = [
  # 海外AIニュース
  "https://techcrunch.com/tag/artificial-intelligence/feed/",
  "https://venturebeat.com/category/ai/feed/",
  "https://www.theverge.com/rss/ai/index.xml",
  "https://www.technologyreview.com/topic/artificial-intelligence/feed",

  # 技術寄り
  "https://feeds.arstechnica.com/arstechnica/technology-lab",
  "https://github.blog/feed/",

  # 公式
  "https://openai.com/blog/rss.xml",
  "https://raw.githubusercontent.com/taobojlen/anthropic-rss-feed/main/anthropic_news_rss.xml",
  "https://blog.google/technology/ai/rss/",

  # 日本
  "https://rss.itmedia.co.jp/rss/2.0/news_ai.xml",
  "https://www.publickey1.jp/atom.xml",
  "https://gigazine.net/news/rss_2.0/"
]

KEYWORDS = %w[OpenAI Google Anthropic LLM GPT Gemini Claude Meta Microsoft].freeze
GEMINI_MODEL = ENV.fetch("GEMINI_MODEL", "gemini-2.0-flash")
AI_RELEVANCE_PATTERNS = [
  /(^|[^a-z])ai([^a-z]|$)/i,
  /人工知能|生成AI|生成ai|機械学習|深層学習|大規模言語モデル|LLM|llm/i,
  /OpenAI|Anthropic|Gemini|Claude|GPT|Copilot|DeepSeek|Mistral|Llama|Perplexity/i,
  /画像生成|音声生成|動画生成|RAG|エージェント|推論|推論モデル|ファインチューニング/i
].freeze

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
def clean_text(raw)
  return "" if raw.nil? || raw.empty?

  raw = raw.encode("UTF-8", invalid: :replace, undef: :replace)

  text = raw
           .gsub(/<\/?[^>]*>/, " ")
  2.times { text = CGI.unescapeHTML(text) }
  text = text.gsub(/&(nbsp|#160|#xA0);/i, " ")
  text = text.gsub(/\u00A0/, " ")
  text = text.gsub(/\s+/, " ").strip

  text
end

BOILERPLATE_PATTERNS = [
  /親愛なる読者/i,
  /サーバー運営がとても苦しい/i,
  /運営継続/i,
  /ご支援|寄付|カンパ/i,
  /広告ブロック/i,
  /ユーザー名|パスワード/i,
  /ユーザー名\s*パスワード\s*-\s*パスワードの再発行/i,
  /ログイン|サインイン|パスワードの再発行/i
].freeze

def ai_related_text?(text)
  t = text.to_s
  AI_RELEVANCE_PATTERNS.any? { |pattern| t.match?(pattern) }
end

def extract_text_from_html(html, max_length: 2500)
  return "" if html.to_s.empty?

  target = html[/<article\b[^>]*>[\s\S]*?<\/article>/i] || html
  cleaned = target.dup
  cleaned.gsub!(/<script\b[^>]*>[\s\S]*?<\/script>/i, " ")
  cleaned.gsub!(/<style\b[^>]*>[\s\S]*?<\/style>/i, " ")
  cleaned.gsub!(/<noscript\b[^>]*>[\s\S]*?<\/noscript>/i, " ")
  cleaned.gsub!(/<!--[\s\S]*?-->/, " ")

  paragraphs = cleaned.scan(/<p\b[^>]*>([\s\S]*?)<\/p>/i).flatten.map { |p| clean_text(p) }
  paragraphs.reject!(&:empty?)
  paragraphs.reject! { |p| BOILERPLATE_PATTERNS.any? { |pattern| p.match?(pattern) } }

  text = if paragraphs.empty?
           clean_text(cleaned)
         else
           clean_text(paragraphs.join(" "))
         end

  BOILERPLATE_PATTERNS.each do |pattern|
    text = text.gsub(pattern, " ")
  end
  text = text.gsub(/\A(?:\s|-|ユーザー名|パスワード|ログイン|サインイン|パスワードの再発行)+/i, " ")
  text = text.gsub(/\s+/, " ").strip

  return "" if text.empty?
  text.length > max_length ? text[0...max_length] : text
end

def fetch_article_body(url, max_length: 2500)
  return "" if url.to_s.empty?

  html = HTTP
         .headers("User-Agent" => "Mozilla/5.0 (compatible; AI-News-Bot/1.0)")
         .timeout(connect: 8, read: 12, write: 8)
         .follow(max_hops: 5)
         .get(url)
         .to_s
  extract_text_from_html(html, max_length: max_length)
rescue => e
  warn "[ARTICLE FETCH ERROR] #{url} #{e.message}"
  ""
end

def usable_article_text?(text)
  t = clean_text(text.to_s)
  return false if t.empty?
  return false if t.length < 120
  return false if BOILERPLATE_PATTERNS.any? { |pattern| t.match?(pattern) }
  return false unless ai_related_text?(t)

  true
end

def fetch_articles(urls, from_time, to_time)
  articles = []

  urls.each do |url|
    begin
      rss_xml = HTTP
                .headers("User-Agent" => "Mozilla/5.0 (compatible; AI-News-Bot/1.0)")
                .timeout(connect: 8, read: 12, write: 8)
                .follow(max_hops: 5)
                .get(url)
                .to_s
      rss = RSS::Parser.parse(rss_xml.force_encoding("UTF-8"), false)
    rescue => e
      warn "[RSS ERROR] #{url} #{e.message}"
      next
    end

    rss.items.each do |item|
      begin
        next unless item.respond_to?(:pubDate) && item.pubDate

        pub_time = Time.parse(item.pubDate.to_s).getlocal(JST)
        next unless pub_time >= from_time && pub_time < to_time

        title = clean_text(item.title.to_s)
        categories = if item.respond_to?(:categories) && item.categories
                       item.categories.map(&:to_s).join(" ")
                     else
                       ""
                     end
        source_text = [title, categories].join(" ")
        ai_focused_source = url.match?(/artificial-intelligence|\/ai\/|news_ai|technology\/ai|openai\.com\/blog\/rss|anthropic\.com\/news\/rss/i)
        next if !ai_focused_source && !ai_related_text?(source_text)

        articles << {
          title: title,
          link: item.link.to_s,
          published: pub_time
        }
      rescue => e
        warn "[RSS ITEM ERROR] #{url} #{e.message}"
        next
      end
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
    "https://generativelanguage.googleapis.com/v1beta/models/#{GEMINI_MODEL}:generateContent?key=#{api_key}",
    json: {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.2,
        maxOutputTokens: 2000
      }
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
      {"index": 1, "title": "..."}
    ]

    #{articles.map.with_index(1) { |a, i| "#{i}. #{a[:title]}" }.join("\n")}
  TEXT
end

def gemini_select(articles)
  return [] if articles.empty?

  raw = call_gemini(build_selection_prompt(articles))

  json_text = raw[/\[[\s\S]*\]/]
  JSON.parse(json_text)
rescue
  articles.first(5).map.with_index(1) { |a, i| { "index" => i, "title" => a[:title] } }
end

def resolve_selected_articles(selected, candidates)
  resolved = selected.map do |sel|
    idx = sel["index"].to_i
    if idx.positive? && idx <= candidates.length
      candidates[idx - 1]
    else
      wanted = normalize_title(sel["title"])
      candidates.find { |a| normalize_title(a[:title]) == wanted }
    end
  end.compact

  deduplicate_articles(resolved)
end

# =========================================
# Gemini: 要約生成
# =========================================
def build_batch_summary_prompt(articles)
  blocks = articles.map.with_index(1) do |article, idx|
    <<~TEXT
      [#{idx}]
      タイトル: #{article[:title]}
      本文抜粋: #{article[:article_text]}
      ---
    TEXT
  end.join("\n")

  <<~TEXT
    次のニュース本文を読み、各記事の要点を日本語で短く作成してください。
    要約は80〜120文字を目安に、1〜2文で完結してください。
    必ず「。」で終わらせてください。
    タイトルの言い換えは禁止。
    固有名詞・数字・変更点を優先。
    曖昧表現は禁止。
    媒体名・著者名・配信日時などのメタ情報は禁止。
    英語は禁止。日本語のみ。
    「...」「…」は禁止。
    出力形式は必ず次の行形式のみ（前置き禁止・コードブロック禁止）。

    1|要約
    2|要約
    3|要約

    #{blocks}
  TEXT
end

def japanese_text?(text)
  text.to_s.match?(/[ぁ-んァ-ン一-龥]/)
end

def sanitize_summary_text(text, max_length: 140)
  cleaned = clean_text(text.to_s)
  cleaned = cleaned.gsub(/\.\.\.+/, "")
  cleaned = cleaned.gsub(/…+/, "")
  cleaned = cleaned.gsub(/\s+/, " ").strip

  return cleaned if cleaned.length <= max_length

  # 文単位で自然に収める
  sentences = cleaned.split(/(?<=[。！？])/)

  result = ""
  sentences.each do |sentence|
    break if (result + sentence).length > max_length
    result += sentence
  end

  # もし何も入らなかったら強制カット
  result = cleaned[0...max_length] if result.strip.empty?

  result.strip
end

def build_local_fallback_summary(article, max_length: 120)
  source = article[:article_text].to_s
  source = article[:title].to_s if source.empty?

  text = clean_text(source)
  text = text
           .gsub(/^[^。]{0,60}(編集部|記者|著)[^。]*。?/i, "")
           .gsub(/\b\d{4}\/\d{1,2}\/\d{1,2}[^。]*。?/, "")
           .gsub(/\b\d{1,2}:\d{2}\b/, "")
           .strip
  if article[:article_text].to_s.empty? || text.empty?
    return "本文を取得できませんでした。リンク先の記事をご確認ください。"
  end

  sentences = text.split(/(?<=[。！？])/).map(&:strip).reject(&:empty?)
  concise = sentences[0].to_s
  concise = text if concise.empty?

  unless japanese_text?(concise)
    title = clean_text(article[:title].to_s)
    concise = "#{title}に関する更新です。詳細はリンク先でご確認ください。"
  end

  sanitize_summary_text(concise, max_length: max_length)
end

def parse_summary_lines(raw, size)
  summaries = {}
  raw.to_s.each_line do |line|
    matched = line.strip.match(/\A(\d{1,2})\s*\|\s*(.+)\z/)
    next unless matched

    idx = matched[1].to_i
    next if idx <= 0 || idx > size

    summary = sanitize_summary_text(matched[2].to_s, max_length: 120)
    next if summary.empty? || !japanese_text?(summary)

    summaries[idx - 1] = summary
  end
  summaries
end

def generate_summaries(articles)
  return {} if articles.empty?

  raw = call_gemini(build_batch_summary_prompt(articles))
  summaries = parse_summary_lines(raw, articles.length)
  summaries
rescue
  {}
end

# =========================================
# Slack Output
# =========================================
def build_slack_text(articles, mention: nil)
  lines = []
  date_str = Time.now.getlocal(JST).strftime("%-m/%-d")

  lines << mention if mention
  lines << "🧠 *#{date_str}のAIニュース*"
  lines << ""

  articles.each_with_index do |article, i|
    lines << "#{i + 1}. *#{article[:title]}*"
    lines << "   👉 #{article[:summary]}"
    lines << "   🔗 <#{article[:link]}|続きを読む>"
    lines << ""
  end

  lines.join("\n")
end

def build_slack_blocks(articles)
  [
    {
      type: "section",
      text: {
        type: "mrkdwn",
        text: build_slack_text(articles, mention: "<!here>")
      }
    }
  ]
end

def post_to_slack(articles)
  webhook = ENV["SLACK_WEBHOOK_URL"]
  raise "SLACK_WEBHOOK_URL missing" if webhook.to_s.empty?

  blocks = build_slack_blocks(articles)
  res = HTTP.post(webhook, json: { blocks: blocks })
  warn "[Slack ERROR] status=#{res.status}" unless res.status.success?
  res.status.success?
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

  # 本文を先に取得し、本文が実用的な候補のみを選定対象にする
  top_articles.each do |article|
    article[:article_text] = fetch_article_body(article[:link])
  end

  body_ready_articles = top_articles.select { |a| usable_article_text?(a[:article_text]) }

  selected = gemini_select(body_ready_articles)
  final_articles = resolve_selected_articles(selected, body_ready_articles)

  # 件数不足時は上位候補から補充（重複除外）
  if final_articles.length < 5
    used_links = final_articles.map { |a| a[:link] }
    refill = body_ready_articles.reject { |a| used_links.include?(a[:link]) }
                       .select { |a| usable_article_text?(a[:article_text]) }
                       .first(5 - final_articles.length)
    final_articles.concat(refill)
  end

  # 要約生成（本文ベース・まとめて1回）
  summaries = generate_summaries(final_articles)
  final_articles.each_with_index do |article, idx|
    article[:summary] = summaries[idx] || build_local_fallback_summary(article)
  end

  if final_articles.empty?
    warn "[INFO] No publishable articles for this run. Slack post skipped."
    return
  end

  post_to_slack(final_articles)
end

run
