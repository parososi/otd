#!/usr/bin/env python3
"""
otd_analysis.py — Análise Estatística OTD com Python

Uso:
    pip install openpyxl pandas
    python otd_analysis.py planilha_otd.xlsx                  # resumo no terminal
    python otd_analysis.py planilha_otd.xlsx --mes 2026-03    # mês específico
    python otd_analysis.py planilha_otd.xlsx --json            # saída JSON
    python otd_analysis.py planilha_otd.xlsx --csv saida.csv   # exporta CSV consolidado
    python otd_analysis.py planilha_otd.xlsx --chart            # gera gráficos PNG (requer matplotlib)

Por que Python:
    - pandas: agrupamento, pivot, percentil em uma linha
    - scipy/numpy: testes estatísticos (Shapiro-Wilk, correlação)
    - openpyxl: lê XLSX sem dependência de servidor
    - matplotlib (opcional): gráficos estáticos para relatórios PDF
    - Pode ser integrado em pipelines CI/CD ou cron jobs
"""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

try:
    import pandas as pd
except ImportError:
    sys.exit("Instale pandas: pip install pandas openpyxl")


# ── Helpers ──────────────────────────────────────────────────────────────────

def parse_date(val):
    """Converte valor para datetime, tratando DD/MM/YYYY e objetos datetime."""
    if isinstance(val, datetime):
        return val
    if pd.isna(val):
        return None
    s = str(val).strip()
    for fmt in ("%d/%m/%Y", "%Y-%m-%d", "%d-%m-%Y"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def calc_dias(prev_ent, dt_fat):
    a, b = parse_date(prev_ent), parse_date(dt_fat)
    if a and b:
        return (b - a).days
    return None


def fmt_money(v):
    """Formata valor em reais."""
    return f"R$ {v:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


# ── Leitura do XLSX ─────────────────────────────────────────────────────────

COLUMN_ALIASES = {
    "pedido":        ["PEDIDO", "NUM PEDIDO"],
    "cliente":       ["CNPJ/CÓD.", "CLIENTE", "CNPJ"],
    "nome_fantasia": ["NOME FANTASIA"],
    "vendedor":      ["VENDEDOR", "NOME VEND"],
    "gerente":       ["GERENTE", "NOME GER"],
    "cod_prod":      ["CÓD. PRODUTO", "COD PROD"],
    "descricao":     ["PRODUTO", "DESCRICAO"],
    "dt_pedido":     ["DT. PEDIDO", "DT PEDIDO"],
    "prev_ent":      ["PREV. ENTREGA", "PREV ENT"],
    "dt_fat":        ["DT. FATURAMENTO", "DT FAT"],
    "dias":          ["DIAS"],
    "vlr_merc":      ["VALOR (R$)", "VLR MERC"],
    "qtde":          ["QTDE", "QUANTIDADE"],
    "situacao":      ["SITUAÇÃO", "SITUACAO"],
    "nf":            ["NF"],
    "motivo":        ["MOTIVO ATRASO", "MOTIVO"],
}


def find_column(headers, aliases):
    """Encontra o índice da coluna pelo nome (case-insensitive)."""
    upper_headers = [h.upper().strip() for h in headers]
    for alias in aliases:
        for i, h in enumerate(upper_headers):
            if h == alias.upper():
                return i
    return None


def load_xlsx(path):
    """Lê XLSX e retorna DataFrame normalizado."""
    df_raw = pd.read_excel(path, engine="openpyxl")
    headers = list(df_raw.columns)

    col_map = {}
    for field, aliases in COLUMN_ALIASES.items():
        idx = find_column(headers, aliases)
        if idx is not None:
            col_map[field] = headers[idx]

    if "pedido" not in col_map:
        sys.exit(f"Coluna PEDIDO não encontrada. Cabeçalhos: {headers[:8]}")
    if "dt_pedido" not in col_map:
        sys.exit(f"Coluna DT PEDIDO não encontrada. Cabeçalhos: {headers[:8]}")

    # Renomear colunas encontradas
    rename = {v: k for k, v in col_map.items()}
    df = df_raw.rename(columns=rename)

    # Manter apenas colunas mapeadas
    cols_to_keep = [c for c in col_map if c in df.columns]
    df = df[cols_to_keep].copy()

    # Parsear datas
    df["dt_pedido"] = df["dt_pedido"].apply(parse_date)
    df = df.dropna(subset=["dt_pedido"])
    df["pedido"] = pd.to_numeric(df.get("pedido"), errors="coerce").fillna(0).astype(int)
    df = df[df["pedido"] > 0].copy()

    # Calcular mk (mês-chave)
    df["mk"] = df["dt_pedido"].apply(lambda d: d.strftime("%Y-%m"))

    # Calcular dias se não presente ou inválido
    if "prev_ent" in df.columns and "dt_fat" in df.columns:
        df["_calc_dias"] = df.apply(lambda r: calc_dias(r.get("prev_ent"), r.get("dt_fat")), axis=1)
        if "dias" in df.columns:
            df["dias"] = pd.to_numeric(df["dias"], errors="coerce")
            df["dias"] = df["dias"].fillna(df["_calc_dias"])
        else:
            df["dias"] = df["_calc_dias"]
        df.drop(columns=["_calc_dias"], inplace=True)

    df["dias"] = pd.to_numeric(df.get("dias", 0), errors="coerce").fillna(0).astype(int)
    df["vlr_merc"] = pd.to_numeric(df.get("vlr_merc", 0), errors="coerce").fillna(0.0)

    return df


# ── Análises ─────────────────────────────────────────────────────────────────

def resumo_mensal(df):
    """Gera resumo por mês: total, no prazo, atrasados, taxa OTD, valor."""
    rows = []
    for mk, g in df.groupby("mk", sort=True):
        total = len(g)
        no_prazo = (g["dias"] <= 0).sum()
        atrasados = (g["dias"] > 0).sum()
        ate5 = ((g["dias"] >= 1) & (g["dias"] <= 5)).sum()
        mais5 = (g["dias"] > 5).sum()
        taxa = round(no_prazo / total * 100, 2) if total else 0
        valor_total = g["vlr_merc"].sum()
        valor_atraso = g.loc[g["dias"] > 0, "vlr_merc"].sum()
        pct_risco = round(valor_atraso / valor_total * 100, 1) if valor_total else 0
        rows.append({
            "mes": mk,
            "total": int(total),
            "no_prazo": int(no_prazo),
            "atrasados": int(atrasados),
            "ate_5d": int(ate5),
            "mais_5d": int(mais5),
            "taxa_otd": taxa,
            "valor_total": round(valor_total, 2),
            "valor_atraso": round(valor_atraso, 2),
            "pct_risco": pct_risco,
        })
    return pd.DataFrame(rows)


def tendencia_otd(resumo_df):
    """Regressão linear sobre taxas OTD mensais (espelha analytics.js getOTDTrend)."""
    taxas = resumo_df["taxa_otd"].tolist()
    n = len(taxas)
    if n < 2:
        return None
    xs = list(range(n))
    sum_x = sum(xs)
    sum_y = sum(taxas)
    sum_xy = sum(x * y for x, y in zip(xs, taxas))
    sum_x2 = sum(x * x for x in xs)
    sum_y2 = sum(y * y for y in taxas)
    denom = n * sum_x2 - sum_x ** 2
    slope = round((n * sum_xy - sum_x * sum_y) / denom, 3) if denom else 0
    denom_r2 = denom * (n * sum_y2 - sum_y ** 2)
    r2 = round((n * sum_xy - sum_x * sum_y) ** 2 / denom_r2, 3) if denom_r2 > 0 else None
    direcao = "subindo" if slope > 0.1 else ("caindo" if slope < -0.1 else "estavel")
    projecao = round(max(0, min(100, taxas[-1] + slope)), 2)
    return {
        "slope_por_mes": slope,
        "r2": r2,
        "direcao": direcao,
        "projecao_prox_mes": projecao,
    }


def ranking_vendedores(df, mk=None):
    """Ranking de vendedores por taxa OTD."""
    g = df[df["mk"] == mk] if mk else df
    if "vendedor" not in g.columns or g.empty:
        return pd.DataFrame()
    stats = g.groupby("vendedor").agg(
        total=("dias", "size"),
        no_prazo=("dias", lambda x: (x <= 0).sum()),
        atrasados=("dias", lambda x: (x > 0).sum()),
        valor=("vlr_merc", "sum"),
    ).reset_index()
    stats["taxa_otd"] = (stats["no_prazo"] / stats["total"] * 100).round(2)
    stats["valor"] = stats["valor"].round(2)
    return stats.sort_values("taxa_otd", ascending=False).reset_index(drop=True)


def risco_clientes(df, mk=None, top_n=10):
    """Score de risco por cliente (espelha analytics.js getClientRiskScores)."""
    g = df[df["mk"] == mk] if mk else df
    col_cliente = "nome_fantasia" if "nome_fantasia" in g.columns else "cliente"
    if col_cliente not in g.columns or g.empty:
        return pd.DataFrame()

    max_dias = max(g["dias"].max(), 1)
    total_valor = max(g["vlr_merc"].sum(), 1)

    results = []
    for c, cg in g.groupby(col_cliente):
        total = len(cg)
        atrasados = (cg["dias"] > 0).sum()
        soma_dias = cg.loc[cg["dias"] > 0, "dias"].sum()
        valor_atr = cg.loc[cg["dias"] > 0, "vlr_merc"].sum()
        freq = atrasados / total if total else 0
        avg_d = soma_dias / atrasados if atrasados else 0
        sev = avg_d / max_dias
        val = valor_atr / total_valor
        score = round((0.4 * freq + 0.35 * sev + 0.25 * val) * 100)
        risco = "alto" if score >= 60 else ("medio" if score >= 30 else "baixo")
        results.append({
            "cliente": c, "total": int(total), "atrasados": int(atrasados),
            "taxa_otd": round((total - atrasados) / total * 100, 2) if total else 0,
            "atraso_medio": round(avg_d, 1),
            "valor_atraso": round(valor_atr, 2),
            "score": score, "risco": risco,
        })
    return pd.DataFrame(results).sort_values("score", ascending=False).head(top_n).reset_index(drop=True)


def dia_semana_otd(df, mk=None):
    """OTD por dia da semana (espelha analytics.js getDayOfWeekOTD)."""
    g = df[df["mk"] == mk] if mk else df
    if "dt_fat" not in g.columns:
        return pd.DataFrame()
    g = g.copy()
    g["_dt_fat_parsed"] = g["dt_fat"].apply(parse_date)
    g = g.dropna(subset=["_dt_fat_parsed"])
    if g.empty:
        return pd.DataFrame()
    DIAS = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sab", "Dom"]
    g["_dow"] = g["_dt_fat_parsed"].apply(lambda d: d.weekday())
    stats = g.groupby("_dow").agg(
        total=("dias", "size"),
        no_prazo=("dias", lambda x: (x <= 0).sum()),
    ).reset_index()
    stats["dia_semana"] = stats["_dow"].map(lambda i: DIAS[i])
    stats["taxa_otd"] = (stats["no_prazo"] / stats["total"] * 100).round(2)
    return stats[["dia_semana", "total", "no_prazo", "taxa_otd"]].reset_index(drop=True)


# ── Saída ────────────────────────────────────────────────────────────────────

def print_resumo(resumo_df, trend, meta=85):
    """Imprime resumo formatado no terminal."""
    print("=" * 70)
    print("  ANALISE OTD — Usiquimica")
    print("=" * 70)
    print()
    print(f"{'Mes':<10} {'Total':>6} {'NoPrazo':>8} {'Atras':>6} {'<=5d':>5} {'>5d':>5} {'OTD%':>7} {'Valor':>16} {'Risco%':>7}")
    print("-" * 70)
    for _, r in resumo_df.iterrows():
        flag = " *" if r["taxa_otd"] < meta else "  "
        print(f"{r['mes']:<10} {r['total']:>6} {r['no_prazo']:>8} {r['atrasados']:>6} "
              f"{r['ate_5d']:>5} {r['mais_5d']:>5} {r['taxa_otd']:>6.2f}%{flag}"
              f" {fmt_money(r['valor_total']):>16} {r['pct_risco']:>6.1f}%")
    print("-" * 70)
    # Totais
    t = resumo_df.sum(numeric_only=True)
    taxa_global = round(t["no_prazo"] / t["total"] * 100, 2) if t["total"] else 0
    print(f"{'TOTAL':<10} {int(t['total']):>6} {int(t['no_prazo']):>8} {int(t['atrasados']):>6} "
          f"{int(t['ate_5d']):>5} {int(t['mais_5d']):>5} {taxa_global:>6.2f}%  "
          f"{fmt_money(t['valor_total']):>16}")
    print()
    if trend:
        print(f"  Tendencia: {trend['direcao']} ({trend['slope_por_mes']:+.3f} pp/mes)")
        if trend["r2"] is not None:
            print(f"  R²: {trend['r2']}")
        print(f"  Projecao proximo mes: {trend['projecao_prox_mes']:.2f}%")
    print()


def generate_charts(resumo_df, trend, output_dir="."):
    """Gera gráficos PNG com matplotlib (opcional)."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib nao instalado — graficos ignorados. pip install matplotlib", file=sys.stderr)
        return

    fig, axes = plt.subplots(2, 2, figsize=(14, 9))
    fig.suptitle("Analise OTD — Usiquimica", fontsize=14, fontweight="bold")

    # 1. Taxa OTD por mes
    ax = axes[0][0]
    colors = ["#27AE60" if t >= 85 else "#EB5757" for t in resumo_df["taxa_otd"]]
    ax.bar(resumo_df["mes"], resumo_df["taxa_otd"], color=colors, edgecolor="white")
    ax.axhline(85, color="#F2994A", linestyle="--", label="Meta 85%")
    ax.set_ylabel("Taxa OTD (%)")
    ax.set_title("Taxa OTD Mensal")
    ax.legend()
    ax.tick_params(axis="x", rotation=45)

    # 2. Pedidos: no prazo vs atrasados
    ax = axes[0][1]
    ax.bar(resumo_df["mes"], resumo_df["no_prazo"], color="#27AE60", label="No prazo")
    ax.bar(resumo_df["mes"], resumo_df["atrasados"], bottom=resumo_df["no_prazo"], color="#EB5757", label="Atrasados")
    ax.set_ylabel("Pedidos")
    ax.set_title("Composicao Mensal")
    ax.legend()
    ax.tick_params(axis="x", rotation=45)

    # 3. Valor em risco
    ax = axes[1][0]
    ax.fill_between(range(len(resumo_df)), resumo_df["pct_risco"], color="#EB5757", alpha=0.3)
    ax.plot(range(len(resumo_df)), resumo_df["pct_risco"], "o-", color="#EB5757")
    ax.set_xticks(range(len(resumo_df)))
    ax.set_xticklabels(resumo_df["mes"], rotation=45)
    ax.set_ylabel("% Valor em Risco")
    ax.set_title("Valor em Risco Mensal")

    # 4. Distribuicao de atraso
    ax = axes[1][1]
    ax.bar(resumo_df["mes"], resumo_df["ate_5d"], color="#F2994A", label="1-5 dias")
    ax.bar(resumo_df["mes"], resumo_df["mais_5d"], bottom=resumo_df["ate_5d"], color="#9B1C1C", label=">5 dias")
    ax.set_ylabel("Pedidos Atrasados")
    ax.set_title("Distribuicao de Atrasos")
    ax.legend()
    ax.tick_params(axis="x", rotation=45)

    plt.tight_layout()
    out_path = Path(output_dir) / "otd_charts.png"
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"  Graficos salvos em: {out_path}")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Analise estatistica OTD — Usiquimica")
    parser.add_argument("arquivo", help="Planilha XLSX de entrada")
    parser.add_argument("--mes", help="Mes especifico YYYY-MM (default: todos)")
    parser.add_argument("--json", action="store_true", help="Saida em formato JSON")
    parser.add_argument("--csv", metavar="SAIDA", help="Exporta resumo para CSV")
    parser.add_argument("--chart", action="store_true", help="Gera graficos PNG")
    parser.add_argument("--meta", type=float, default=85, help="Meta OTD em %% (default: 85)")
    parser.add_argument("--vendedores", action="store_true", help="Inclui ranking de vendedores")
    parser.add_argument("--clientes", action="store_true", help="Inclui score de risco por cliente")
    args = parser.parse_args()

    if not Path(args.arquivo).exists():
        sys.exit(f"Arquivo nao encontrado: {args.arquivo}")

    df = load_xlsx(args.arquivo)
    if df.empty:
        sys.exit("Nenhum pedido valido encontrado na planilha.")

    resumo = resumo_mensal(df)
    trend = tendencia_otd(resumo)

    if args.json:
        output = {
            "resumo": resumo.to_dict(orient="records"),
            "tendencia": trend,
            "total_pedidos": int(resumo["total"].sum()),
            "gerado_em": datetime.now().isoformat(),
        }
        if args.vendedores:
            output["vendedores"] = ranking_vendedores(df, args.mes).to_dict(orient="records")
        if args.clientes:
            output["clientes_risco"] = risco_clientes(df, args.mes).to_dict(orient="records")
        print(json.dumps(output, ensure_ascii=False, indent=2, default=str))
    else:
        print_resumo(resumo, trend, args.meta)
        if args.vendedores:
            rv = ranking_vendedores(df, args.mes)
            if not rv.empty:
                print("  RANKING VENDEDORES")
                print("  " + "-" * 60)
                for _, v in rv.iterrows():
                    print(f"  {v['vendedor']:<20} OTD: {v['taxa_otd']:>6.2f}%  "
                          f"Total: {v['total']:>4}  Atras: {v['atrasados']:>3}  "
                          f"Valor: {fmt_money(v['valor'])}")
                print()
        if args.clientes:
            rc = risco_clientes(df, args.mes)
            if not rc.empty:
                print("  TOP 10 CLIENTES — RISCO")
                print("  " + "-" * 60)
                for _, c in rc.iterrows():
                    print(f"  [{c['score']:>3}] {c['cliente'][:25]:<25} OTD: {c['taxa_otd']:>6.2f}%  "
                          f"Atras: {c['atrasados']:>3}  Risco: {c['risco']}")
                print()

    if args.csv:
        resumo.to_csv(args.csv, sep=";", index=False, encoding="utf-8-sig")
        print(f"  CSV exportado: {args.csv}")

    if args.chart:
        generate_charts(resumo, trend)


if __name__ == "__main__":
    main()
