#!/usr/bin/env ruby
# generate_report.rb — Gerador Automático de Relatório Mensal OTD
#
# Uso:
#   gem install roo
#   ruby generate_report.rb planilha_otd.xlsx [YYYY-MM]
#   ruby generate_report.rb planilha_otd.xlsx              # usa o mês mais recente
#   ruby generate_report.rb planilha_otd.xlsx 2026-03      # mês específico
#
# Gera um arquivo HTML formatado para impressão ou envio por e-mail.
# Também pode ser convertido para PDF com:
#   wkhtmltopdf relatorio_otd_2026-03.html relatorio_otd_2026-03.pdf
#
# Por que Ruby:
#   - Date.strptime suporta DD/MM/YYYY nativamente
#   - Hash.group_by espelha o acumulador months[mk] do JavaScript
#   - gem roo lê o mesmo formato XLSX sem servidor, como o dashboard
#   - Fácil de agendar como cron job para envio automático mensal

require "date"
require "json"

begin
  require "roo"
rescue LoadError
  abort "Instale a gem roo: gem install roo"
end

# ─── Helpers de data ────────────────────────────────────────────────────────

def parse_dmy(s)
  return nil if s.nil? || s.to_s.strip.empty?
  Date.strptime(s.to_s.strip, "%d/%m/%Y")
rescue Date::Error
  nil
end

def calc_dias(prev_ent, dt_fat)
  a = parse_dmy(prev_ent)
  b = parse_dmy(dt_fat)
  return 0 if a.nil? || b.nil?
  (b - a).to_i
end

def fmt_date(d)
  return "—" if d.nil?
  d.is_a?(Date) ? d.strftime("%d/%m/%Y") : d.to_s
end

def fmt_money(v)
  v ||= 0.0
  format("R$ %,.2f", v).gsub(",", "X").gsub(".", ",").gsub("X", ".")
end

# ─── Análise (espelha analytics.js) ─────────────────────────────────────────

def calc_taxa_otd(pedidos)
  return 0.0 if pedidos.empty?
  no_prazo = pedidos.count { |p| p[:dias] <= 0 }
  (no_prazo.to_f / pedidos.size * 100).round(2)
end

def get_otd_trend(monthly_rates)
  n = monthly_rates.size
  return nil if n < 2
  sum_x  = (0...n).sum
  sum_y  = monthly_rates.sum
  sum_xy = monthly_rates.each_with_index.sum { |y, i| i * y }
  sum_x2 = (0...n).sum { |i| i * i }
  denom  = n * sum_x2 - sum_x**2
  slope  = denom != 0 ? ((n * sum_xy - sum_x * sum_y).to_f / denom).round(3) : 0.0
  # R²
  sum_y2 = monthly_rates.sum { |y| y * y }
  denom_r2 = denom * (n * sum_y2 - sum_y**2)
  r2 = denom_r2 > 0 ? ((n * sum_xy - sum_x * sum_y)**2.0 / denom_r2).round(3) : nil
  {
    slope:    slope,
    r2:       r2,
    direcao:  slope > 0.1 ? "subindo" : slope < -0.1 ? "caindo" : "estável"
  }
end

def get_vendedor_ranking(pedidos)
  map = Hash.new { |h, k| h[k] = { vendedor: k, total: 0, no_prazo: 0, atrasados: 0, valor: 0.0 } }
  pedidos.each do |p|
    v = p[:vendedor].to_s.strip.then { |s| s.empty? ? "—" : s }
    map[v][:total]     += 1
    map[v][:no_prazo]  += 1 if p[:dias] <= 0
    map[v][:atrasados] += 1 if p[:dias] > 0
    map[v][:valor]     += p[:vlr_merc].to_f
  end
  map.values
    .map { |e| e.merge(taxa_otd: (e[:no_prazo].to_f / e[:total] * 100).round(2)) }
    .sort_by { |e| -e[:taxa_otd] }
end

def get_client_risk(pedidos)
  return [] if pedidos.empty?
  max_dias      = pedidos.map { |p| [p[:dias], 0].max }.max.then { |m| m > 0 ? m : 1 }
  total_valor   = pedidos.sum { |p| p[:vlr_merc].to_f }.then { |v| v > 0 ? v : 1 }
  map = Hash.new { |h, k| h[k] = { cliente: k, total: 0, atrasados: 0, soma_dias: 0, valor_atrasado: 0.0, valor_total: 0.0 } }
  pedidos.each do |p|
    c = p[:nome_fantasia].to_s.strip.then { |s| s.empty? ? p[:cliente].to_s : s }
    map[c][:total]  += 1
    map[c][:valor_total] += p[:vlr_merc].to_f
    if p[:dias] > 0
      map[c][:atrasados]      += 1
      map[c][:soma_dias]      += p[:dias]
      map[c][:valor_atrasado] += p[:vlr_merc].to_f
    end
  end
  map.values.map do |e|
    freq  = e[:total] > 0 ? e[:atrasados].to_f / e[:total] : 0
    avg_d = e[:atrasados] > 0 ? e[:soma_dias].to_f / e[:atrasados] : 0
    sev   = avg_d / max_dias
    val   = e[:valor_atrasado] / total_valor
    score = ((0.4 * freq + 0.35 * sev + 0.25 * val) * 100).round
    e.merge(score: score, risco: score >= 60 ? "alto" : score >= 30 ? "médio" : "baixo")
  end.sort_by { |e| -e[:score] }.first(10)
end

# ─── Leitura do XLSX ────────────────────────────────────────────────────────

abort "Uso: ruby generate_report.rb planilha.xlsx [YYYY-MM]" if ARGV.empty?
xlsx_path = ARGV[0]
target_mk = ARGV[1]  # opcional

abort "Arquivo não encontrado: #{xlsx_path}" unless File.exist?(xlsx_path)

wb = Roo::Spreadsheet.open(xlsx_path)

# Detecta a aba com mais linhas (mesmo comportamento do importXLSX)
sheet_name = wb.sheets.max_by { |s| wb.sheet(s).last_row.to_i }
ws = wb.sheet(sheet_name)

headers = ws.row(1).map { |h| h.to_s.strip }

col = ->(names) {
  names.each do |n|
    idx = headers.index { |h| h.upcase == n.upcase }
    return idx if idx
  end
  nil
}

cols = {
  pedido:        col.(["PEDIDO", "NUM PEDIDO"]),
  cliente:       col.(["CNPJ/CÓD.", "CLIENTE", "CNPJ"]),
  nome_fantasia: col.(["CLIENTE", "NOME FANTASIA"]),
  vendedor:      col.(["VENDEDOR", "NOME VEND"]),
  gerente:       col.(["GERENTE", "NOME GER"]),
  cod_prod:      col.(["CÓD. PRODUTO", "COD PROD"]),
  descricao:     col.(["PRODUTO", "DESCRICAO"]),
  dt_pedido:     col.(["DT. PEDIDO", "DT PEDIDO"]),
  prev_ent:      col.(["PREV. ENTREGA", "PREV ENT"]),
  dt_fat:        col.(["DT. FATURAMENTO", "DT FAT"]),
  dias:          col.(["DIAS"]),
  vlr_merc:      col.(["VALOR (R$)", "VLR MERC"]),
  qtde:          col.(["QTDE", "QUANTIDADE"]),
  situacao:      col.(["SITUAÇÃO", "SITUACAO"]),
  nf:            col.(["NF"]),
  motivo:        col.(["MOTIVO ATRASO", "MOTIVO"])
}

abort "Coluna PEDIDO não encontrada. Cabeçalhos: #{headers.first(8).join(", ")}" if cols[:pedido].nil?

all_pedidos = []
(2..ws.last_row).each do |row_i|
  row = ws.row(row_i)
  pnum = row[cols[:pedido]].to_i
  next if pnum == 0

  dt_ped_raw = cols[:dt_pedido] ? row[cols[:dt_pedido]] : nil
  dt_ped = if dt_ped_raw.is_a?(Date)
    dt_ped_raw
  elsif dt_ped_raw.to_s.strip.match?(%r{\A\d{2}/\d{2}/\d{4}\z})
    Date.strptime(dt_ped_raw.to_s.strip, "%d/%m/%Y") rescue nil
  elsif dt_ped_raw.to_s.strip.match?(%r{\A\d{4}-\d{2}-\d{2}\z})
    Date.strptime(dt_ped_raw.to_s.strip, "%Y-%m-%d") rescue nil
  else
    Date.parse(dt_ped_raw.to_s) rescue nil
  end
  next if dt_ped.nil?

  mk = dt_ped.strftime("%Y-%m")
  prev_ent = cols[:prev_ent] ? row[cols[:prev_ent]].to_s.strip : ""
  dt_fat   = cols[:dt_fat]   ? row[cols[:dt_fat]].to_s.strip   : ""

  # Para células Date retornadas pelo roo, converter para DD/MM/YYYY
  if cols[:prev_ent] && row[cols[:prev_ent]].is_a?(Date)
    prev_ent = row[cols[:prev_ent]].strftime("%d/%m/%Y")
  end
  if cols[:dt_fat] && row[cols[:dt_fat]].is_a?(Date)
    dt_fat = row[cols[:dt_fat]].strftime("%d/%m/%Y")
  end

  dias_raw = cols[:dias] ? row[cols[:dias]].to_s.strip : ""
  dias = dias_raw.match?(/^-?\d+$/) ? dias_raw.to_i : calc_dias(prev_ent, dt_fat)

  all_pedidos << {
    pedido:        pnum,
    mk:            mk,
    cliente:       cols[:cliente]       ? row[cols[:cliente]].to_s       : "",
    nome_fantasia: cols[:nome_fantasia] ? row[cols[:nome_fantasia]].to_s  : "",
    vendedor:      cols[:vendedor]      ? row[cols[:vendedor]].to_s       : "",
    gerente:       cols[:gerente]       ? row[cols[:gerente]].to_s        : "",
    cod_prod:      cols[:cod_prod]      ? row[cols[:cod_prod]].to_s       : "",
    descricao:     cols[:descricao]     ? row[cols[:descricao]].to_s      : "",
    dt_pedido:     dt_ped,
    prev_ent:      prev_ent,
    dt_fat:        dt_fat,
    dias:          dias,
    vlr_merc:      cols[:vlr_merc]      ? row[cols[:vlr_merc]].to_f       : 0.0,
    qtde:          cols[:qtde]          ? row[cols[:qtde]].to_i           : 0,
    situacao:      cols[:situacao]      ? row[cols[:situacao]].to_s       : "",
    nf:            cols[:nf]            ? row[cols[:nf]].to_i             : 0,
    motivo:        cols[:motivo]        ? row[cols[:motivo]].to_s         : ""
  }
end

abort "Nenhum pedido válido encontrado na planilha." if all_pedidos.empty?

# Agrupar por mês
by_month = all_pedidos.group_by { |p| p[:mk] }

# Selecionar mês alvo
available_months = by_month.keys.sort
if target_mk
  abort "Mês #{target_mk} não encontrado. Disponíveis: #{available_months.join(", ")}" unless by_month.key?(target_mk)
  target_mk_key = target_mk
else
  target_mk_key = available_months.last
end

pedidos = by_month[target_mk_key]
all_monthly_rates = available_months.map { |mk| calc_taxa_otd(by_month[mk]) }
trend = get_otd_trend(all_monthly_rates)

# ─── Métricas do mês ────────────────────────────────────────────────────────

total          = pedidos.size
no_prazo       = pedidos.count { |p| p[:dias] <= 0 }
exata          = pedidos.count { |p| p[:dias] == 0 }
adiantados     = pedidos.count { |p| p[:dias] < 0 }
atrasados      = pedidos.count { |p| p[:dias] > 0 }
ate5           = pedidos.count { |p| p[:dias] >= 1 && p[:dias] <= 5 }
mais5          = pedidos.count { |p| p[:dias] > 5 }
taxa_otd       = calc_taxa_otd(pedidos)
valor_total    = pedidos.sum { |p| p[:vlr_merc] }
valor_atrasado = pedidos.select { |p| p[:dias] > 0 }.sum { |p| p[:vlr_merc] }
pct_risco      = valor_total > 0 ? (valor_atrasado / valor_total * 100).round(1) : 0

meta_otd = 85  # Padrão; ajuste conforme config.js

mes_names = %w[Janeiro Fevereiro Março Abril Maio Junho
               Julho Agosto Setembro Outubro Novembro Dezembro]
y, mo = target_mk_key.split("-").map(&:to_i)
label_mes = "#{mes_names[mo - 1]} #{y}"

vendedores      = get_vendedor_ranking(pedidos)
clientes_risco  = get_client_risk(pedidos)

# ─── Gerar HTML ──────────────────────────────────────────────────────────────

out_file = "relatorio_otd_#{target_mk_key}.html"
generated_at = Time.now.strftime("%d/%m/%Y %H:%M")

html = <<~HTML
  <!DOCTYPE html>
  <html lang="pt-BR">
  <head>
  <meta charset="UTF-8">
  <title>Relatório OTD — #{label_mes}</title>
  <style>
    body{font-family:Arial,sans-serif;color:#222;margin:0;padding:0;background:#f0f2f5}
    .page{max-width:960px;margin:0 auto;background:#fff;padding:32px 36px}
    h1{color:#1a3a6b;font-size:1.5rem;margin-bottom:4px}
    .subtitle{color:#888;font-size:.9rem;margin-bottom:28px}
    .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:28px}
    .kpi{background:#f5f7fc;border-radius:10px;padding:14px 12px;text-align:center;border-top:4px solid #ccc}
    .kpi-label{font-size:.68rem;color:#999;font-weight:700;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
    .kpi-value{font-size:1.8rem;font-weight:800;line-height:1}
    h2{color:#1a3a6b;font-size:1rem;margin:24px 0 10px;border-bottom:2px solid #eef1f8;padding-bottom:6px}
    table{width:100%;border-collapse:collapse;font-size:.84rem;margin-bottom:24px}
    th{background:#f5f7fc;color:#555;font-weight:700;padding:8px 10px;text-align:left;border-bottom:2px solid #e8ecf4}
    td{padding:7px 10px;border-bottom:1px solid #eef1f8}
    .ok{color:#27AE60;font-weight:700}.bad{color:#EB5757;font-weight:700}
    .warn{color:#F2994A;font-weight:700}
    .badge{display:inline-block;padding:2px 8px;border-radius:20px;font-size:.73rem;font-weight:700;color:#fff}
    .badge-ok{background:#27AE60}.badge-warn{background:#F2994A}.badge-err{background:#EB5757}
    .risk-high{background:#EB5757;color:#fff;padding:2px 8px;border-radius:20px;font-size:.73rem;font-weight:700}
    .risk-med{background:#F2994A;color:#fff;padding:2px 8px;border-radius:20px;font-size:.73rem;font-weight:700}
    .risk-low{background:#27AE60;color:#fff;padding:2px 8px;border-radius:20px;font-size:.73rem;font-weight:700}
    .footer{color:#aaa;font-size:.75rem;margin-top:32px;border-top:1px solid #eee;padding-top:12px;text-align:center}
    @media print{body{background:#fff}.page{padding:0}}
  </style>
  </head>
  <body>
  <div class="page">
    <h1>📦 Relatório OTD — #{label_mes}</h1>
    <div class="subtitle">Usiquímica · Gerado em #{generated_at} · Meta: #{meta_otd}%</div>

    <div class="kpis">
      <div class="kpi" style="border-color:#1a3a6b">
        <div class="kpi-label">Total de Pedidos</div>
        <div class="kpi-value" style="color:#1a3a6b">#{total}</div>
      </div>
      <div class="kpi" style="border-color:#{taxa_otd >= meta_otd ? "#27AE60" : "#EB5757"}">
        <div class="kpi-label">Taxa OTD</div>
        <div class="kpi-value" style="color:#{taxa_otd >= meta_otd ? "#27AE60" : "#EB5757"}">#{taxa_otd.to_s.sub(".", ",")}%</div>
      </div>
      <div class="kpi" style="border-color:#27AE60">
        <div class="kpi-label">No Prazo</div>
        <div class="kpi-value" style="color:#27AE60">#{no_prazo}</div>
      </div>
      <div class="kpi" style="border-color:#EB5757">
        <div class="kpi-label">Atrasados</div>
        <div class="kpi-value" style="color:#EB5757">#{atrasados}</div>
      </div>
      <div class="kpi" style="border-color:#1e88e5">
        <div class="kpi-label">Data Exata</div>
        <div class="kpi-value" style="color:#1e88e5">#{exata}</div>
      </div>
      <div class="kpi" style="border-color:#56CCF2">
        <div class="kpi-label">Adiantados</div>
        <div class="kpi-value" style="color:#56CCF2">#{adiantados}</div>
      </div>
      <div class="kpi" style="border-color:#F2994A">
        <div class="kpi-label">Até 5d Atraso</div>
        <div class="kpi-value" style="color:#F2994A">#{ate5}</div>
      </div>
      <div class="kpi" style="border-color:#9B1C1C">
        <div class="kpi-label">Valor em Risco</div>
        <div class="kpi-value" style="color:#9B1C1C;font-size:1.1rem">#{pct_risco}%</div>
      </div>
    </div>
HTML

# Tendência
if trend
  direcao_txt = trend[:direcao] == "subindo" ? "↑ Subindo" : trend[:direcao] == "caindo" ? "↓ Caindo" : "→ Estável"
  r2_txt = trend[:r2] ? " (R²=#{trend[:r2]})" : ""
  html += <<~SECTION
    <h2>📈 Tendência OTD</h2>
    <table>
      <thead><tr><th>Indicador</th><th>Valor</th></tr></thead>
      <tbody>
        <tr><td>Direção</td><td>#{direcao_txt}</td></tr>
        <tr><td>Inclinação mensal (slope)</td><td>#{trend[:slope]} pp/mês#{r2_txt}</td></tr>
        <tr><td>Meses analisados</td><td>#{available_months.size}</td></tr>
        <tr><td>Meses disponíveis</td><td>#{available_months.join(", ")}</td></tr>
      </tbody>
    </table>
  SECTION
end

# Ranking de vendedores
html += "<h2>👤 Ranking de Vendedores</h2>\n"
html += "<table><thead><tr><th>#</th><th>Vendedor</th><th>Total</th><th>No Prazo</th><th>Atrasados</th><th>Taxa OTD</th><th>Valor Total</th></tr></thead><tbody>\n"
vendedores.each_with_index do |v, i|
  badge_cls = v[:taxa_otd] >= meta_otd ? "badge-ok" : v[:taxa_otd] >= meta_otd * 0.8 ? "badge-warn" : "badge-err"
  html += "<tr><td>#{i+1}</td><td>#{v[:vendedor]}</td><td>#{v[:total]}</td><td>#{v[:no_prazo]}</td><td>#{v[:atrasados]}</td>"
  html += "<td><span class=\"badge #{badge_cls}\">#{v[:taxa_otd]}%</span></td>"
  html += "<td>#{fmt_money(v[:valor])}</td></tr>\n"
end
html += "</tbody></table>\n"

# Score de risco por cliente
unless clientes_risco.empty?
  html += "<h2>👥 Top 10 Clientes — Score de Risco</h2>\n"
  html += "<table><thead><tr><th>Score</th><th>Cliente</th><th>Atrasados</th><th>Taxa OTD</th><th>Atraso Médio</th><th>Valor em Risco</th></tr></thead><tbody>\n"
  clientes_risco.each do |c|
    risk_cls = c[:risco] == "alto" ? "risk-high" : c[:risco] == "médio" ? "risk-med" : "risk-low"
    avg_d = c[:atrasados] > 0 ? (c[:soma_dias].to_f / c[:atrasados]).round(1) : 0
    html += "<tr><td><span class=\"#{risk_cls}\">#{c[:score]}</span></td>"
    html += "<td>#{c[:cliente]}</td><td>#{c[:atrasados]}</td>"
    html += "<td>#{(((c[:total]-c[:atrasados]).to_f/c[:total])*100).round(1)}%</td>"
    html += "<td>#{avg_d > 0 ? "#{avg_d}d" : "—"}</td>"
    html += "<td>#{fmt_money(c[:valor_atrasado])}</td></tr>\n"
  end
  html += "</tbody></table>\n"
end

html += <<~FOOTER
    <div class="footer">
      Relatório gerado automaticamente por generate_report.rb · #{generated_at}<br>
      Fonte de dados: #{File.basename(xlsx_path)} · Mês: #{label_mes}
    </div>
  </div>
  </body>
  </html>
FOOTER

File.write(out_file, html)
puts "✅ Relatório gerado: #{out_file}"
puts "   Mês: #{label_mes} | Total: #{total} pedidos | OTD: #{taxa_otd}%"
puts "   Para PDF: wkhtmltopdf #{out_file} relatorio_otd_#{target_mk_key}.pdf"
