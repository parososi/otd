// analytics.js — Funções de análise de dados do Dashboard OTD
// Uso: OTDAnalytics.<função>(otdData.months, ...)
// Todas as funções são puras (sem efeitos colaterais).

window.OTDAnalytics = (function () {

  // ── Resumo acumulado de todos os meses ────────────────────────────────────
  // Retorna totais globais: pedidos, OTD médio, atrasos, adiantamentos, etc.
  function getSummary(months) {
    const keys = Object.keys(months).sort();
    if (!keys.length) return null;
    let totalPedidos = 0, totalNoPrazo = 0, totalAtrasados = 0, totalAdiantados = 0;
    let totalMais5 = 0, totalAte5 = 0, totalValor = 0;
    keys.forEach(k => {
      const m = months[k];
      totalPedidos   += m.totalPedidos       || 0;
      totalNoPrazo   += m.pedidosNoPrazo     || 0;
      totalAtrasados += m.pedidosAtrasados   || 0;
      totalAdiantados+= m.pedidosAdiantados  || 0;
      totalMais5     += m.pedidosMais5DiasAtraso || 0;
      totalAte5      += m.pedidosAte5DiasAtraso  || 0;
      (m.pedidos || []).forEach(p => { totalValor += p.vlrMerc || 0; });
    });
    const taxaOTDMedia = totalPedidos ? +(totalNoPrazo / totalPedidos * 100).toFixed(2) : 0;
    return {
      meses: keys.length,
      totalPedidos,
      totalNoPrazo,
      totalAtrasados,
      totalAdiantados,
      totalAte5DiasAtraso: totalAte5,
      totalMais5DiasAtraso: totalMais5,
      taxaOTDMedia,
      totalValorMercadoria: +totalValor.toFixed(2),
    };
  }

  // ── Tendência da taxa OTD ao longo dos meses ──────────────────────────────
  // Retorna: direção ("subindo"|"caindo"|"estável"), melhor e pior mês, variação total.
  function getOTDTrend(months) {
    const keys = Object.keys(months).sort();
    if (keys.length < 2) return null;
    const taxas = keys.map(k => ({ mk: k, label: months[k].label, taxa: months[k].taxaOTD }));
    const first = taxas[0].taxa, last = taxas[taxas.length - 1].taxa;
    const delta = +(last - first).toFixed(2);
    const melhor = taxas.reduce((a, b) => b.taxa > a.taxa ? b : a);
    const pior   = taxas.reduce((a, b) => b.taxa < a.taxa ? b : a);
    // Regressão linear simples para inclinação
    const n = taxas.length;
    const sumX = taxas.reduce((s, _, i) => s + i, 0);
    const sumY = taxas.reduce((s, t) => s + t.taxa, 0);
    const sumXY = taxas.reduce((s, t, i) => s + i * t.taxa, 0);
    const sumX2 = taxas.reduce((s, _, i) => s + i * i, 0);
    const slope = +((n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)).toFixed(3);
    return {
      direcao: slope > 0.1 ? "subindo" : slope < -0.1 ? "caindo" : "estável",
      slopePorMes: slope,
      variacaoTotal: delta,
      melhorMes: { mk: melhor.mk, label: melhor.label, taxa: melhor.taxa },
      piorMes:   { mk: pior.mk,   label: pior.label,   taxa: pior.taxa   },
      historico: taxas,
    };
  }

  // ── Ranking de vendedores por OTD% (mês específico) ──────────────────────
  // mk = "2026-03". Retorna array ordenado do melhor ao pior.
  function getVendedorRanking(months, mk) {
    const m = months[mk]; if (!m) return [];
    const map = {};
    (m.pedidos || []).forEach(p => {
      const v = p.vendedor || "—";
      if (!map[v]) map[v] = { vendedor: v, total: 0, noPrazo: 0, atrasados: 0, valorTotal: 0 };
      map[v].total++;
      if (p.dias <= 0) map[v].noPrazo++;
      else             map[v].atrasados++;
      map[v].valorTotal += p.vlrMerc || 0;
    });
    return Object.values(map)
      .map(e => ({ ...e, taxaOTD: +(e.noPrazo / e.total * 100).toFixed(2), valorTotal: +e.valorTotal.toFixed(2) }))
      .sort((a, b) => b.taxaOTD - a.taxaOTD);
  }

  // ── Ranking de gerentes por OTD% (mês específico) ────────────────────────
  function getGerenteRanking(months, mk) {
    const m = months[mk]; if (!m) return [];
    const map = {};
    (m.pedidos || []).forEach(p => {
      const g = p.gerente || "—";
      if (!map[g]) map[g] = { gerente: g, total: 0, noPrazo: 0, atrasados: 0, valorTotal: 0 };
      map[g].total++;
      if (p.dias <= 0) map[g].noPrazo++;
      else             map[g].atrasados++;
      map[g].valorTotal += p.vlrMerc || 0;
    });
    return Object.values(map)
      .map(e => ({ ...e, taxaOTD: +(e.noPrazo / e.total * 100).toFixed(2), valorTotal: +e.valorTotal.toFixed(2) }))
      .sort((a, b) => b.taxaOTD - a.taxaOTD);
  }

  // ── Distribuição dos motivos de atraso (mês específico) ──────────────────
  // motivoAssignments = window.motivoAssignments, motivosAtraso = CFG.motivosAtraso
  function getMotivoDistribution(months, mk, motivoAssignments, motivosAtraso) {
    const m = months[mk]; if (!m) return [];
    const atrasados = (m.pedidos || []).filter(p => p.dias > 0);
    const total = atrasados.length;
    const counts = motivosAtraso.map((mot, i) => {
      const peds = atrasados.filter(p => motivoAssignments[mk + ":" + p.pedido] === i);
      return {
        indice: i,
        motivo: mot,
        quantidade: peds.length,
        pct: total ? +(peds.length / total * 100).toFixed(1) : 0,
        valorTotal: +peds.reduce((s, p) => s + (p.vlrMerc || 0), 0).toFixed(2),
        atrasoMedio: peds.length ? +(peds.reduce((s, p) => s + p.dias, 0) / peds.length).toFixed(1) : 0,
      };
    });
    const semMotivo = atrasados.filter(p => motivoAssignments[mk + ":" + p.pedido] === undefined);
    counts.push({
      indice: -1,
      motivo: "Sem motivo atribuído",
      quantidade: semMotivo.length,
      pct: total ? +(semMotivo.length / total * 100).toFixed(1) : 0,
      valorTotal: +semMotivo.reduce((s, p) => s + (p.vlrMerc || 0), 0).toFixed(2),
      atrasoMedio: semMotivo.length ? +(semMotivo.reduce((s, p) => s + p.dias, 0) / semMotivo.length).toFixed(1) : 0,
    });
    return counts.sort((a, b) => b.quantidade - a.quantidade);
  }

  // ── Comparação entre dois meses ───────────────────────────────────────────
  // Retorna deltas (positivo = cresceu, negativo = caiu) entre mk1 e mk2.
  function compareMonths(months, mk1, mk2) {
    const a = months[mk1], b = months[mk2];
    if (!a || !b) return null;
    const delta = (fa, fb) => +(fb - fa).toFixed(2);
    return {
      de: { mk: mk1, label: a.label },
      para: { mk: mk2, label: b.label },
      totalPedidos:    { de: a.totalPedidos,       para: b.totalPedidos,       delta: delta(a.totalPedidos,       b.totalPedidos) },
      pedidosNoPrazo:  { de: a.pedidosNoPrazo,     para: b.pedidosNoPrazo,     delta: delta(a.pedidosNoPrazo,     b.pedidosNoPrazo) },
      taxaOTD:         { de: a.taxaOTD,             para: b.taxaOTD,             delta: delta(a.taxaOTD,             b.taxaOTD) },
      pedidosAtrasados:{ de: a.pedidosAtrasados,   para: b.pedidosAtrasados,   delta: delta(a.pedidosAtrasados,   b.pedidosAtrasados) },
      mais5DiasAtraso: { de: a.pedidosMais5DiasAtraso, para: b.pedidosMais5DiasAtraso, delta: delta(a.pedidosMais5DiasAtraso, b.pedidosMais5DiasAtraso) },
    };
  }

  return { getSummary, getOTDTrend, getVendedorRanking, getGerenteRanking, getMotivoDistribution, compareMonths };
})();
