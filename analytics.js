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
    let totalMais5 = 0, totalAte5 = 0, totalValor = 0, totalValorAtrasado = 0;
    keys.forEach(k => {
      const m = months[k];
      totalPedidos   += m.totalPedidos       || 0;
      totalNoPrazo   += m.pedidosNoPrazo     || 0;
      totalAtrasados += m.pedidosAtrasados   || 0;
      totalAdiantados+= m.pedidosAdiantados  || 0;
      totalMais5     += m.pedidosMais5DiasAtraso || 0;
      totalAte5      += m.pedidosAte5DiasAtraso  || 0;
      (m.pedidos || []).forEach(p => {
        totalValor += p.vlrMerc || 0;
        if (p.dias > 0) totalValorAtrasado += p.vlrMerc || 0;
      });
    });
    const taxaOTDMedia = totalPedidos ? +(totalNoPrazo / totalPedidos * 100).toFixed(2) : 0;
    const pctValorAtrasado = totalValor ? +(totalValorAtrasado / totalValor * 100).toFixed(1) : 0;
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
      totalValorAtrasado: +totalValorAtrasado.toFixed(2),
      pctValorAtrasado,
    };
  }

  // ── Tendência da taxa OTD ao longo dos meses ──────────────────────────────
  // Retorna: direção ("subindo"|"caindo"|"estável"), melhor e pior mês, variação total,
  // inclinação (slopePorMes) e coeficiente de determinação R².
  function getOTDTrend(months) {
    const keys = Object.keys(months).sort();
    if (keys.length < 2) return null;
    const taxas = keys.map(k => ({ mk: k, label: months[k].label, taxa: months[k].taxaOTD }));
    const first = taxas[0].taxa, last = taxas[taxas.length - 1].taxa;
    const delta = +(last - first).toFixed(2);
    const melhor = taxas.reduce((a, b) => b.taxa > a.taxa ? b : a);
    const pior   = taxas.reduce((a, b) => b.taxa < a.taxa ? b : a);
    // Regressão linear simples para inclinação e R²
    const n = taxas.length;
    const sumX  = taxas.reduce((s, _, i) => s + i, 0);
    const sumY  = taxas.reduce((s, t) => s + t.taxa, 0);
    const sumXY = taxas.reduce((s, t, i) => s + i * t.taxa, 0);
    const sumX2 = taxas.reduce((s, _, i) => s + i * i, 0);
    const sumY2 = taxas.reduce((s, t) => s + t.taxa * t.taxa, 0);
    const denom = (n * sumX2 - sumX * sumX);
    const slope = denom ? +((n * sumXY - sumX * sumY) / denom).toFixed(3) : 0;
    // R² = (n·ΣXY − ΣX·ΣY)² / [(n·ΣX²−(ΣX)²)·(n·ΣY²−(ΣY)²)]
    const denomR2 = denom * (n * sumY2 - sumY * sumY);
    const r2 = denomR2 > 0
      ? +(Math.pow(n * sumXY - sumX * sumY, 2) / denomR2).toFixed(3)
      : null;
    return {
      direcao: slope > 0.1 ? "subindo" : slope < -0.1 ? "caindo" : "estável",
      slopePorMes: slope,
      r2,
      variacaoTotal: delta,
      melhorMes: { mk: melhor.mk, label: melhor.label, taxa: melhor.taxa },
      piorMes:   { mk: pior.mk,   label: pior.label,   taxa: pior.taxa   },
      historico: taxas,
    };
  }

  // ── Projeção do próximo mês baseada na tendência ──────────────────────────
  // Retorna a taxa OTD projetada (capped 0–100) usando a regressão linear de getOTDTrend.
  function projectNextMonth(trend) {
    if (!trend || trend.historico.length < 2) return null;
    const last = trend.historico[trend.historico.length - 1].taxa;
    return Math.max(0, Math.min(100, +(last + trend.slopePorMes).toFixed(2)));
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

  // ── Ranking de produtos por OTD% (mês específico) ────────────────────────
  function getProductRanking(months, mk) {
    const m = months[mk]; if (!m) return [];
    const map = {};
    (m.pedidos || []).forEach(p => {
      const key = (p.codProd || "—") + "||" + (p.descricao || "—");
      if (!map[key]) map[key] = { codProd: p.codProd || "—", descricao: p.descricao || "—", total: 0, noPrazo: 0, atrasados: 0, valorTotal: 0 };
      map[key].total++;
      if (p.dias <= 0) map[key].noPrazo++;
      else             map[key].atrasados++;
      map[key].valorTotal += p.vlrMerc || 0;
    });
    return Object.values(map)
      .map(e => ({ ...e, taxaOTD: +(e.noPrazo / e.total * 100).toFixed(2), valorTotal: +e.valorTotal.toFixed(2) }))
      .sort((a, b) => b.atrasados - a.atrasados || a.taxaOTD - b.taxaOTD);
  }

  // ── Score de risco por cliente ────────────────────────────────────────────
  // Score composto 0–100: 40% frequência de atraso + 35% severidade + 25% valor exposto.
  function getClientRiskScores(months, mk) {
    const m = months[mk]; if (!m) return [];
    const pedidos = m.pedidos || [];
    if (!pedidos.length) return [];
    const maxDias = pedidos.reduce((mx, p) => Math.max(mx, p.dias || 0), 0) || 1;
    const totalValorMes = pedidos.reduce((s, p) => s + (p.vlrMerc || 0), 0) || 1;
    const map = {};
    pedidos.forEach(p => {
      const c = p.nomeFantasia || p.cliente || "—";
      if (!map[c]) map[c] = { cliente: c, total: 0, atrasados: 0, somaDias: 0, valorAtrasado: 0, valorTotal: 0 };
      map[c].total++;
      map[c].valorTotal += p.vlrMerc || 0;
      if (p.dias > 0) {
        map[c].atrasados++;
        map[c].somaDias += p.dias;
        map[c].valorAtrasado += p.vlrMerc || 0;
      }
    });
    return Object.values(map).map(e => {
      const freqScore  = e.atrasados / e.total;
      const avgDias    = e.atrasados ? e.somaDias / e.atrasados : 0;
      const sevScore   = avgDias / maxDias;
      const valScore   = e.valorAtrasado / totalValorMes;
      const score      = Math.round((0.4 * freqScore + 0.35 * sevScore + 0.25 * valScore) * 100);
      return {
        cliente: e.cliente,
        total: e.total,
        atrasados: e.atrasados,
        taxaOTD: +(((e.total - e.atrasados) / e.total) * 100).toFixed(2),
        atrasoMedioDias: e.atrasados ? +(e.somaDias / e.atrasados).toFixed(1) : 0,
        valorAtrasado: +e.valorAtrasado.toFixed(2),
        valorTotal: +e.valorTotal.toFixed(2),
        score,
        risco: score >= 60 ? "alto" : score >= 30 ? "medio" : "baixo",
      };
    }).sort((a, b) => b.score - a.score);
  }

  // ── OTD por dia da semana (mês específico) ────────────────────────────────
  // Agrupa dtFat por dia da semana para detectar padrões (ex: "efeito sexta").
  function getDayOfWeekOTD(months, mk) {
    const m = months[mk]; if (!m) return [];
    const DIAS = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"];
    const map = {};
    for (let i = 0; i < 7; i++) map[i] = { diaSemana: i, label: DIAS[i], total: 0, noPrazo: 0 };
    (m.pedidos || []).forEach(p => {
      if (!p.dtFat) return;
      // dtFat pode ser "DD/MM/YYYY" ou "YYYY-MM-DD"
      let parts, d;
      if (p.dtFat.includes("/")) {
        parts = p.dtFat.split("/");
        d = new Date(+parts[2], +parts[1] - 1, +parts[0]);
      } else {
        parts = p.dtFat.split("-");
        d = new Date(+parts[0], +parts[1] - 1, +parts[2]);
      }
      if (isNaN(d.getTime())) return;
      const dow = d.getDay();
      map[dow].total++;
      if (p.dias <= 0) map[dow].noPrazo++;
    });
    return Object.values(map)
      .filter(e => e.total > 0)
      .map(e => ({ ...e, taxaOTD: +(e.noPrazo / e.total * 100).toFixed(2) }));
  }

  // ── Distribuição dos motivos de atraso (mês específico) ──────────────────
  // motivoAssignments = window.motivoAssignments, motivosAtraso = CFG.motivosAtraso
  function getMotivoDistribution(months, mk, motivoAssignments, motivosAtraso) {
    motivoAssignments = motivoAssignments || {};
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

  // ── Breakdown por tiers de SLA ────────────────────────────────────────────
  // slaThresholds = [0, 3, 7] → tiers: no prazo | 1-3 dias | 4-7 dias | 8+ dias
  function getSLABreakdown(months, mk, slaThresholds) {
    const m = months[mk]; if (!m) return [];
    const thresholds = slaThresholds || [0, 3, 7];
    const pedidos = m.pedidos || [];
    const total = pedidos.length;
    // Monta os tiers: [no prazo] + [th[0]+1..th[1]] + [th[1]+1..th[2]] + [th[last]+1..]
    const tiers = [];
    tiers.push({ label: "No prazo", min: null, max: 0 });
    for (let i = 0; i < thresholds.length; i++) {
      const min = thresholds[i] + 1;
      const max = i < thresholds.length - 1 ? thresholds[i + 1] : null;
      const label = max !== null
        ? `${min}–${max} dias`
        : `${min}+ dias`;
      tiers.push({ label, min, max });
    }
    return tiers.map(tier => {
      let peds;
      if (tier.max === 0) {
        peds = pedidos.filter(p => p.dias <= 0);
      } else if (tier.max === null) {
        peds = pedidos.filter(p => p.dias >= tier.min);
      } else {
        peds = pedidos.filter(p => p.dias >= tier.min && p.dias <= tier.max);
      }
      return {
        label: tier.label,
        quantidade: peds.length,
        pct: total ? +(peds.length / total * 100).toFixed(1) : 0,
        valorTotal: +peds.reduce((s, p) => s + (p.vlrMerc || 0), 0).toFixed(2),
      };
    });
  }

  // ── Comparação entre dois meses ───────────────────────────────────────────
  // Retorna deltas (positivo = cresceu, negativo = caiu) entre mk1 e mk2.
  function compareMonths(months, mk1, mk2) {
    const a = months[mk1], b = months[mk2];
    if (!a || !b) return null;
    const delta = (fa, fb) => +(fb - fa).toFixed(2);
    const valorAtrasadoA = (a.pedidos || []).filter(p => p.dias > 0).reduce((s, p) => s + (p.vlrMerc || 0), 0);
    const valorAtrasadoB = (b.pedidos || []).filter(p => p.dias > 0).reduce((s, p) => s + (p.vlrMerc || 0), 0);
    return {
      de: { mk: mk1, label: a.label },
      para: { mk: mk2, label: b.label },
      totalPedidos:    { de: a.totalPedidos,       para: b.totalPedidos,       delta: delta(a.totalPedidos,       b.totalPedidos) },
      pedidosNoPrazo:  { de: a.pedidosNoPrazo,     para: b.pedidosNoPrazo,     delta: delta(a.pedidosNoPrazo,     b.pedidosNoPrazo) },
      taxaOTD:         { de: a.taxaOTD,             para: b.taxaOTD,             delta: delta(a.taxaOTD,             b.taxaOTD) },
      pedidosAtrasados:{ de: a.pedidosAtrasados,   para: b.pedidosAtrasados,   delta: delta(a.pedidosAtrasados,   b.pedidosAtrasados) },
      mais5DiasAtraso: { de: a.pedidosMais5DiasAtraso, para: b.pedidosMais5DiasAtraso, delta: delta(a.pedidosMais5DiasAtraso, b.pedidosMais5DiasAtraso) },
      valorAtrasado:   { de: +valorAtrasadoA.toFixed(2), para: +valorAtrasadoB.toFixed(2), delta: delta(valorAtrasadoA, valorAtrasadoB) },
    };
  }

  // ── Comparação ano a ano ──────────────────────────────────────────────────
  // Para cada mês em months, busca o mesmo mês-calendário do ano anterior.
  function getYoYComparison(months) {
    return Object.keys(months).sort().map(mk => {
      const [y, mo] = mk.split("-");
      const priorKey = `${parseInt(y) - 1}-${mo}`;
      const cur = months[mk];
      const hasPrior = priorKey in months;
      const prior = hasPrior ? months[priorKey] : null;
      return {
        mk,
        label: cur.label,
        taxaOTD: cur.taxaOTD,
        priorMk: priorKey,
        priorTaxaOTD: hasPrior ? prior.taxaOTD : null,
        delta: hasPrior ? +(cur.taxaOTD - prior.taxaOTD).toFixed(2) : null,
        direcao: !hasPrior ? null : cur.taxaOTD > prior.taxaOTD ? "subindo" : cur.taxaOTD < prior.taxaOTD ? "caindo" : "estável",
      };
    });
  }

  return {
    getSummary,
    getOTDTrend,
    projectNextMonth,
    getVendedorRanking,
    getGerenteRanking,
    getProductRanking,
    getClientRiskScores,
    getDayOfWeekOTD,
    getMotivoDistribution,
    getSLABreakdown,
    compareMonths,
    getYoYComparison,
  };
})();
