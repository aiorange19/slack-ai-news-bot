# frozen_string_literal: true

require "rss"
require "json"
require "http"
require "time"
require "cgi"

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
  "https://www.publickey1.jp/atom.xml",
  "https://gigazine.net/news/rss_2.0/"
]

KEYWORDS = %w[OpenAI Google Anthropic LLM GPT Gemini Claude Meta Microsoft].freeze
GEMINI_MODEL = ENV.fetch("GEMINI_MODEL", "gemini-2.5-flash-lite")
GEMINI_MAX_CALLS_PER_RUN = ENV.fetch("GEMINI_MAX_CALLS_PER_RUN", "2").to_i
SUMMARY_SOURCE_MAX_CHARS = 1200
SUMMARY_MIN_PARAGRAPH_CHARS = 40
AI_RELEVANCE_PATTERNS = [
  /(^|[^a-z])ai([^a-z]|$)/i,
  /人工知能|生成AI|生成ai|機械学習|深層学習|大規模言語モデル|LLM|llm/i,
  /OpenAI|Anthropic|Gemini|Claude|GPT|Copilot|DeepSeek|Mistral|Llama|Perplexity/i,
  /画像生成|音声生成|動画生成|RAG|エージェント|推論|推論モデル|ファインチューニング/i
].freeze
BOILERPLATE_PATTERNS = [
  /cookie/i,
  /プライバシー|利用規約|会員登録|ログイン|サインイン/i,
  /広告|スポンサー|購読|ニュースレター/i,
  /subscribe|subscription|sign in|log in/i,
  /この記事をシェア|関連記事|おすすめ記事/i
].freeze

# =========================================
# Orchestration
# =========================================
def run
  @gemini_call_count = 0

  from_time, to_time = day_window_jst

  articles = fetch_articles(RSS_URLS, from_time, to_time)
  articles = deduplicate_articles(articles)

  add_scores(articles)
  top_articles = pick_top_articles(articles, limit: 10)
  final_articles = select_final_articles(top_articles, limit: 5)

  # 要約生成（タイトルとリンクをもとにまとめて1回）
  summaries = generate_summaries(final_articles)
  if summaries.length < final_articles.length
    warn "[SUMMARY WARN] generated=#{summaries.length}/#{final_articles.length} fallback=#{final_articles.length - summaries.length}"
  end

  final_articles.each_with_index do |article, idx|
    article[:summary] = summaries[idx] || build_local_fallback_summary(article)
  end

  if final_articles.empty?
    warn "[INFO] No publishable articles for this run. Slack post skipped."
    return
  end

  post_to_slack(final_articles)
end

private

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
# RSSフィードを巡回し、指定したJST時間窓内の記事かつAI_RELEVANCE_PATTERNSに該当したものを収集して返す
# =========================================
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
        feed_summary = if item.respond_to?(:description) && item.description
                         clean_text(item.description.to_s)
                       else
                         ""
                       end
        categories = if item.respond_to?(:categories) && item.categories
                       item.categories.map(&:to_s).join(" ")
                     else
                       ""
                     end
        source_text = [title, categories].join(" ")
        # AI特化ソースURLか本文のAI関連キーワードのどちらかに該当した記事のみ残す
        ai_focused_source = url.match?(/artificial-intelligence|\/ai\/|news_ai|technology\/ai|openai\.com\/blog\/rss|anthropic\.com\/news\/rss/i)
        next if !ai_focused_source && !ai_related_text?(source_text)

        articles << {
          title: title,
          link: item.link.to_s,
          published: pub_time,
          feed_summary: feed_summary
        }
      rescue => e
        warn "[RSS ITEM ERROR] #{url} #{e.message}"
        next
      end
    end
  end

  articles
end

# nbsp等の不要な文字列を削除
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

def ai_related_text?(text)
  t = text.to_s
  AI_RELEVANCE_PATTERNS.any? { |pattern| t.match?(pattern) }
end

# =========================================
# スコア付け（タイトル内のキーワード一致数で優先度を決める）
# =========================================
def add_scores(articles)
  articles.each do |article|
    article[:score] = KEYWORDS.count { |k| article[:title].include?(k) }
  end
end

def pick_top_articles(articles, limit: 10)
  articles.sort_by { |a| -a[:score] }.first(limit)
end

def select_final_articles(top_articles, limit: 5)
  return [] if top_articles.empty?
  return top_articles.first(limit) if top_articles.length <= limit

  if gemini_calls_remaining < 2
    warn "[SELECT WARN] not enough Gemini budget. use local top #{limit}."
    return top_articles.first(limit)
  end

  selected = gemini_select(top_articles, limit: limit)
  final_articles = resolve_selected_articles(selected, top_articles, limit: limit)

  if final_articles.length < limit
    used_links = final_articles.map { |article| article[:link] }
    refill = top_articles.reject { |article| used_links.include?(article[:link]) }
                         .first(limit - final_articles.length)
    final_articles.concat(refill)
  end

  deduplicate_articles(final_articles).first(limit)
end

def gemini_select(articles, limit: 5)
  raw = call_gemini(build_selection_prompt(articles, limit: limit), response_mime_type: "application/json")
  parse_selection_json(raw, limit: limit)
rescue => e
  warn "[SELECT WARN] fallback local due to parse error: #{e.message}"
  articles.first(limit).map.with_index(1) { |article, idx| { "index" => idx, "title" => article[:title] } }
end

def build_selection_prompt(articles, limit: 5)
  <<~TEXT
    次のニュース候補から重要度の高い#{limit}件を選んでください。
    意味が重複する候補は1件にまとめてください。
    出力はJSON配列のみ。各要素は index と title を含めてください。

    [
      {"index": 1, "title": "..."}
    ]

    #{articles.map.with_index(1) { |article, idx| "#{idx}. #{article[:title]}" }.join("\n")}
  TEXT
end

def parse_selection_json(raw, limit: 5)
  json_text = raw.to_s[/\[[\s\S]*\]/]
  raise "selection json not found" if json_text.to_s.empty?

  parsed = JSON.parse(json_text)
  raise "selection json is not array" unless parsed.is_a?(Array)

  parsed.first(limit).map do |row|
    {
      "index" => row["index"],
      "title" => row["title"]
    }
  end
end

def resolve_selected_articles(selected, candidates, limit: 5)
  resolved = selected.map do |sel|
    idx = sel["index"].to_i
    if idx.positive? && idx <= candidates.length
      candidates[idx - 1]
    else
      wanted = normalize_title(sel["title"])
      candidates.find { |article| normalize_title(article[:title]) == wanted }
    end
  end.compact

  deduplicate_articles(resolved).first(limit)
end

# =========================================
# Gemini: 要約生成
# =========================================
def generate_summaries(articles)
  return {} if articles.empty?

  articles.each do |article|
    source_text = fetch_article_source_text(article[:link])
    source_text = article[:feed_summary].to_s if source_text.empty?
    article[:source_text] = source_text
  end

  raw = call_gemini(build_batch_summary_prompt(articles), response_mime_type: "application/json")
  parse_summary_lines(raw, articles.length)
rescue
  {}
end

def build_batch_summary_prompt(articles)
  blocks = articles.map.with_index(1) do |article, idx|
    source_text = article[:source_text].to_s.strip
    source_text = "（本文取得失敗。タイトルのみで要約）" if source_text.empty?

    <<~TEXT
      [#{idx}]
      タイトル: #{article[:title]}
      リンク: #{article[:link]}
      本文抜粋: #{source_text}
      ---
    TEXT
  end.join("\n")

  <<~TEXT
    次のニュース情報（タイトル・本文抜粋）を根拠に、各記事の要点を日本語で短く作成してください。
    本文抜粋にある事実（固有名詞・数字・変更点）を優先し、推測はしないでください。
    リンクURLの文字列そのものを根拠にしないでください。
    本文抜粋が「（本文取得失敗。タイトルのみで要約）」のときだけ、タイトルから推定して要約してください。
    要約は80〜120文字を目安に、1〜2文で完結してください。
    必ず「。」で終わらせてください。
    文体は、ニュースをおすすめする紹介文として、やわらかい「です・ます調」にしてください。
    断定的で硬い行政文書のような言い回し（例: 〜である、〜とされる）を避けてください。
    タイトルの言い換えは禁止。
    固有名詞・数字・変更点を優先。
    曖昧表現は禁止。
    媒体名・著者名・配信日時などのメタ情報は禁止。
    出力は日本語のみ。ただし固有名詞（組織名・製品名・人物名）は原文の英語表記を許可。
    「...」「…」は禁止。
    出力は必ずJSONのみ（前置き禁止・コードブロック禁止）。
    必ず全件分（index 1〜#{articles.length}）を含めてください。
    JSON形式:
    {"summaries":[{"index":1,"summary":"要約"}, {"index":2,"summary":"要約"}]}

    #{blocks}
  TEXT
end

def fetch_article_source_text(url)
  return "" if url.to_s.empty?

  html = HTTP
         .headers("User-Agent" => "Mozilla/5.0 (compatible; AI-News-Bot/1.0)")
         .timeout(connect: 8, read: 12, write: 8)
         .follow(max_hops: 5)
         .get(url)
         .to_s

  html_to_readable_text(html, max_length: SUMMARY_SOURCE_MAX_CHARS)
rescue => e
  warn "[ARTICLE FETCH ERROR] #{url} #{e.message}"
  ""
end

def html_to_readable_text(html, max_length: 1200)
  raw = html.to_s
  target = raw[/<article\b[^>]*>[\s\S]*?<\/article>/im] ||
           raw[/<main\b[^>]*>[\s\S]*?<\/main>/im] ||
           raw

  body = target
         .gsub(/<script[\s\S]*?<\/script>/im, " ")
         .gsub(/<style[\s\S]*?<\/style>/im, " ")
         .gsub(/<noscript[\s\S]*?<\/noscript>/im, " ")
         .gsub(/<svg[\s\S]*?<\/svg>/im, " ")
         .gsub(/<iframe[\s\S]*?<\/iframe>/im, " ")

  paragraphs = body.scan(/<p\b[^>]*>([\s\S]*?)<\/p>/im).flatten
                   .map { |p| clean_text(p) }
                   .reject { |t| t.length < SUMMARY_MIN_PARAGRAPH_CHARS }
                   .reject { |t| BOILERPLATE_PATTERNS.any? { |pat| t.match?(pat) } }

  cleaned = if paragraphs.empty?
              clean_text(body)
            else
              paragraphs.first(8).join(" ")
            end

  cleaned = cleaned.gsub(/\s+/, " ").strip
  return "" if cleaned.empty?

  trim_text_naturally(cleaned, max_length: max_length)
end

def trim_text_naturally(text, max_length: 1200)
  cleaned = text.to_s.strip
  return cleaned if cleaned.length <= max_length

  sentences = cleaned.split(/(?<=[。！？.!?])/)
  result = ""
  sentences.each do |sentence|
    break if (result + sentence).length > max_length
    result += sentence
  end
  result = cleaned[0...max_length] if result.strip.empty?
  result.strip
end

def build_local_fallback_summary(article, max_length: 120)
  title = clean_text(article[:title].to_s)
  concise = "#{title}に関する更新です。詳細はリンク先でご確認ください。"
  sanitize_summary_text(concise, max_length: max_length)
end

def parse_summary_lines(raw, size)
  text = raw.to_s
  summaries = parse_summary_json_payload(text, size)
  return summaries if summaries.length >= size

  text.each_line do |line|
    parsed = parse_indexed_summary_line(line, size)
    next unless parsed

    idx, summary = parsed
    summaries[idx] = summary
    break if summaries.length >= size
  end

  summaries
end

def parse_summary_json_payload(raw, size)
  json_part = raw.to_s[/\{[\s\S]*\}|\[[\s\S]*\]/]
  return {} if json_part.to_s.empty?

  begin
    parsed = JSON.parse(json_part)
  rescue
    return {}
  end

  rows = if parsed.is_a?(Hash) && parsed["summaries"].is_a?(Array)
           parsed["summaries"]
         elsif parsed.is_a?(Array)
           parsed
         else
           []
         end

  summaries = {}
  rows.each do |row|
    next unless row.is_a?(Hash)

    idx = (row["index"] || row["id"] || row["no"]).to_i
    next if idx <= 0 || idx > size

    raw_summary = row["summary"] || row["text"] || row["body"]
    summary = sanitize_summary_text(raw_summary.to_s, max_length: 120)
    next if summary.empty?

    summaries[idx - 1] = summary
  end

  summaries
end

def parse_indexed_summary_line(line, size)
  text = line.to_s.strip
  return nil if text.empty?

  matched = text.match(/\A\[*\s*(\d{1,2})\s*\]*\s*(?:\||[:：\-]|[.)])\s*(.+)\z/)
  return nil unless matched

  idx = matched[1].to_i
  return nil if idx <= 0 || idx > size

  summary = sanitize_summary_text(matched[2].to_s, max_length: 120)
  return nil if summary.empty?

  [idx - 1, summary]
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

# =========================================
# 重複除去（タイトルを正規化して同一記事を1件にまとめる）
# =========================================
def deduplicate_articles(articles)
  seen = {}
  articles.reject do |article|
    key = normalize_title(article[:title])
    seen[key] ? true : (seen[key] = true; false)
  end
end

def normalize_title(text)
  text.to_s.downcase.gsub(/[^a-z0-9ぁ-んァ-ン一-龥]/, "")
end

# =========================================
# Gemini Common Caller
# =========================================
def call_gemini(prompt, response_mime_type: nil)
  if gemini_call_limit_reached?
    warn "[Gemini FAIL] call_limit_reached count=#{@gemini_call_count}"
    return ""
  end

  api_key = ENV["GEMINI_API_KEY"]
  if api_key.to_s.strip.empty?
    warn "[Gemini FAIL] GEMINI_API_KEY missing"
    return ""
  end

  generation_config = {
    temperature: 0.2,
    maxOutputTokens: 2000
  }
  generation_config[:responseMimeType] = response_mime_type if response_mime_type.to_s != ""

  response = HTTP.post(
    "https://generativelanguage.googleapis.com/v1beta/models/#{GEMINI_MODEL}:generateContent?key=#{api_key}",
    json: {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: generation_config
    }
  )
  increment_gemini_call_count

  unless response.status.success?
    warn "[Gemini FAIL] model=#{GEMINI_MODEL} status=#{response.status}"
    return ""
  end

  result = JSON.parse(response.body.to_s)
  if result["error"]
    msg = result.dig("error", "message").to_s
    warn "[Gemini FAIL] model=#{GEMINI_MODEL} api_error=#{truncate_for_log(msg)}"
    return ""
  end

  text = result.dig("candidates", 0, "content", "parts", 0, "text").to_s
  if text.strip.empty?
    warn "[Gemini FAIL] model=#{GEMINI_MODEL} empty_response"
    return ""
  end

  warn "[Gemini OK] model=#{GEMINI_MODEL} chars=#{text.length} call_count=#{@gemini_call_count}"
  text
rescue => e
  warn "[Gemini FAIL] model=#{GEMINI_MODEL} reason=#{truncate_for_log(e.message)}"
  ""
end

def gemini_call_limit_reached?
  current = @gemini_call_count.to_i
  limit = GEMINI_MAX_CALLS_PER_RUN.positive? ? GEMINI_MAX_CALLS_PER_RUN : 2
  current >= limit
end

def gemini_calls_remaining
  limit = GEMINI_MAX_CALLS_PER_RUN.positive? ? GEMINI_MAX_CALLS_PER_RUN : 2
  [limit - @gemini_call_count.to_i, 0].max
end

def increment_gemini_call_count
  @gemini_call_count = @gemini_call_count.to_i + 1
end

def truncate_for_log(text, max_length: 300)
  clean = text.to_s.gsub(/\s+/, " ").strip
  clean.length > max_length ? "#{clean[0...max_length]}..." : clean
end

# =========================================
# Slack Output
# =========================================
def post_to_slack(articles)
  webhook = ENV["SLACK_WEBHOOK_URL"]
  raise "SLACK_WEBHOOK_URL missing" if webhook.to_s.empty?

  blocks = build_slack_blocks(articles)
  res = HTTP.post(webhook, json: { blocks: blocks })
  warn "[Slack ERROR] status=#{res.status}" unless res.status.success?
  res.status.success?
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

run
