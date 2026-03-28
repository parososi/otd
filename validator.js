/**
 * OTD Dashboard — Validador de Integridade de Dados
 * Inclua na página ou abra no console do browser: OTDValidator.run()
 *
 * Uso:
 *   <script src="validator.js"></script>
 *   OTDValidator.run();           // audit completo
 *   OTDValidator.report();        // exibe relatório formatado
 *   OTDValidator.fixData();       // tenta corrigir inconsistências automaticamente
 */
(function(window){
  "use strict";

  const V = {};

  // ─── Helpers ────────────────────────────────────────────────────────────
  function parseD(s){
    if(!s) return null;
    const p = String(s).trim().split("/");
    if(p.length!==3) return null;
    const d = new Date(+p[2], +p[1]-1, +p[0]);
    return isNaN(d.getTime()) ? null : d;
  }

  function calcDias(prevEnt, dtFat){
    const a = parseD(prevEnt), b = parseD(dtFat);
    if(!a || !b) return null;
    return Math.round((b - a) / 86400000);
  }

  // ─── Core audit ─────────────────────────────────────────────────────────
  V.run = function(){
    const results = { errors:[], warnings:[], info:[] };
    const data = window.otdData;

    if(!data){ results.errors.push("window.otdData não encontrado — data.js não carregado."); V._last=results; return results; }
    if(!data.months || !Object.keys(data.months).length){ results.errors.push("window.otdData.months está vazio."); V._last=results; return results; }

    const cfg = (window.DASHBOARD_CONFIG && window.DASHBOARD_CONFIG.otd) || {};
    const nMotivos = (cfg.motivosAtraso||[]).length;

    results.info.push(`Meses carregados: ${Object.keys(data.months).join(", ")}`);
    results.info.push(`exportedAt: ${data.exportedAt||"NÃO DEFINIDO"}`);

    let totalPeds = 0;

    Object.entries(data.months).forEach(([mk, m]) => {
      const peds = m.pedidos || [];
      totalPeds += peds.length;

      // ── Derived-field consistency ──────────────────────────────────────
      const computedNP  = peds.filter(p => p.dias <= 0).length;
      const computedAt  = peds.filter(p => p.dias > 0).length;
      const computedEx  = peds.filter(p => p.dias === 0).length;
      const computedAd  = peds.filter(p => p.dias < 0).length;
      const computedA5  = peds.filter(p => p.dias >= 1 && p.dias <= 5).length;
      const computedM5  = peds.filter(p => p.dias > 5).length;
      const computedT   = peds.length;
      const computedOTD = computedT > 0 ? Math.round(computedNP / computedT * 10000) / 100 : 0;

      if(computedT !== m.totalPedidos)
        results.errors.push(`[${mk}] totalPedidos=${m.totalPedidos} mas pedidos.length=${computedT}`);
      if(computedNP !== m.pedidosNoPrazo)
        results.errors.push(`[${mk}] pedidosNoPrazo=${m.pedidosNoPrazo} mas calculado=${computedNP}`);
      if(computedAt !== m.pedidosAtrasados)
        results.errors.push(`[${mk}] pedidosAtrasados=${m.pedidosAtrasados} mas calculado=${computedAt}`);
      if(computedEx !== m.pedidosDataExata)
        results.errors.push(`[${mk}] pedidosDataExata=${m.pedidosDataExata} mas calculado=${computedEx}`);
      if(computedAd !== m.pedidosAdiantados)
        results.errors.push(`[${mk}] pedidosAdiantados=${m.pedidosAdiantados} mas calculado=${computedAd}`);
      if(computedA5 !== m.pedidosAte5DiasAtraso)
        results.errors.push(`[${mk}] pedidosAte5DiasAtraso=${m.pedidosAte5DiasAtraso} mas calculado=${computedA5}`);
      if(computedM5 !== m.pedidosMais5DiasAtraso)
        results.errors.push(`[${mk}] pedidosMais5DiasAtraso=${m.pedidosMais5DiasAtraso} mas calculado=${computedM5}`);
      if(Math.abs(computedOTD - m.taxaOTD) > 0.02)
        results.errors.push(`[${mk}] taxaOTD=${m.taxaOTD}% mas calculado=${computedOTD}%`);

      // ── distribuicaoAtraso consistency ────────────────────────────────
      const da = m.distribuicaoAtraso || {};
      [1,2,3,4,5].forEach(d => {
        const expected = peds.filter(p => p.dias === d).length;
        if((da[String(d)]||0) !== expected)
          results.errors.push(`[${mk}] distribuicaoAtraso["${d}"]=${da[String(d)]||0} mas real=${expected}`);
      });
      const expected_n5 = peds.filter(p => p.dias > 5).length;
      if((da["n>5"]||0) !== expected_n5)
        results.errors.push(`[${mk}] distribuicaoAtraso["n>5"]=${da["n>5"]||0} mas real=${expected_n5}`);

      // ── Per-pedido checks ─────────────────────────────────────────────
      const seen = new Set();
      peds.forEach((p, i) => {
        const id = `[${mk}] pedido ${p.pedido}`;

        if(!p.pedido) results.errors.push(`${id}: pedido number missing (row ${i})`);
        if(!p.nomeFantasia && !p.cliente) results.warnings.push(`${id}: sem nome e sem CNPJ`);
        if(p.prevEnt && p.dtFat){
          const recalc = calcDias(p.prevEnt, p.dtFat);
          if(recalc !== null && Math.abs(recalc - p.dias) > 0)
            results.warnings.push(`${id}: DIAS=${p.dias} mas DT FAT−PREV ENT=${recalc}`);
        }
        if(Math.abs(p.dias) > 365)
          results.errors.push(`${id}: DIAS=${p.dias} — valor absurdo (>365 dias), provável erro de data`);
        if(p.vlrMerc < 0)
          results.errors.push(`${id}: VLR MERC=${p.vlrMerc} — valor negativo`);
        if(!p.dtPedido)
          results.warnings.push(`${id}: dtPedido ausente`);
        // Check dtPedido format
        if(p.dtPedido && !/^\d{4}-\d{2}-\d{2}$/.test(String(p.dtPedido)))
          results.warnings.push(`${id}: dtPedido formato inesperado: "${p.dtPedido}"`);

        // Dedup within month
        const dupKey = `${p.pedido}-${p.nf}-${p.dtFat}`;
        if(seen.has(dupKey))
          results.warnings.push(`${id}: duplicata detectada (mesmo pedido+NF+data faturamento)`);
        seen.add(dupKey);
      });

      results.info.push(`[${mk}] ${computedT} pedidos — OTD: ${computedOTD}% — Atrasados: ${computedAt}`);
    });

    // ── motivoAssignments cross-check ────────────────────────────────────
    const ma = (function(){ try{ return JSON.parse(localStorage.getItem("motivoAssignments")||"{}"); }catch(e){return{};} })();
    Object.entries(ma).forEach(([key, idx]) => {
      if(typeof idx !== "number" || idx < 0 || idx >= nMotivos)
        results.errors.push(`motivoAssignments["${key}"]=${idx} — fora do range de motivosAtraso (0–${nMotivos-1})`);
      const [mk, pedStr] = key.split(":");
      if(mk && pedStr && data.months[mk]){
        const pedNum = parseInt(pedStr);
        const exists = (data.months[mk].pedidos||[]).some(p => p.pedido === pedNum);
        if(!exists)
          results.warnings.push(`motivoAssignments: pedido ${pedNum} do mês ${mk} não existe mais nos dados`);
      }
    });

    results.info.push(`Total pedidos auditados: ${totalPeds}`);
    results.info.push(`motivoAssignments entries: ${Object.keys(ma).length}`);

    V._last = results;
    return results;
  };

  // ─── Formatted report ───────────────────────────────────────────────────
  V.report = function(){
    const r = V.run();
    const sep = "─".repeat(60);
    console.log("\n%cOTD Dashboard — Relatório de Integridade", "font-size:14px;font-weight:bold;color:#1a3a6b");
    console.log(sep);

    if(r.errors.length){
      console.group(`%c❌ ERROS (${r.errors.length})`, "color:#EB5757;font-weight:bold");
      r.errors.forEach(e => console.error(e));
      console.groupEnd();
    } else {
      console.log("%c✅ Nenhum erro encontrado", "color:#27AE60;font-weight:bold");
    }

    if(r.warnings.length){
      console.group(`%c⚠️  AVISOS (${r.warnings.length})`, "color:#F2994A;font-weight:bold");
      r.warnings.forEach(w => console.warn(w));
      console.groupEnd();
    }

    console.group("%cℹ️  INFO", "color:#888");
    r.info.forEach(i => console.info(i));
    console.groupEnd();

    console.log(sep);
    console.log(`Total: ${r.errors.length} erros, ${r.warnings.length} avisos`);
    if(r.errors.length > 0)
      console.log("%c💡 Dica: execute OTDValidator.fixData() para tentar corrigir automaticamente", "color:#1a3a6b");
    return r;
  };

  // ─── Auto-fix ───────────────────────────────────────────────────────────
  V.fixData = function(){
    const data = window.otdData;
    if(!data || !data.months){ console.error("otdData não disponível"); return; }
    let fixed = 0;

    Object.entries(data.months).forEach(([mk, m]) => {
      const peds = m.pedidos || [];

      // Recompute all derived fields from pedidos array
      const noPrazo     = peds.filter(p => p.dias <= 0).length;
      const atrasados   = peds.filter(p => p.dias > 0).length;
      const dataExata   = peds.filter(p => p.dias === 0).length;
      const adiantados  = peds.filter(p => p.dias < 0).length;
      const ate5        = peds.filter(p => p.dias >= 1 && p.dias <= 5).length;
      const mais5       = peds.filter(p => p.dias > 5).length;
      const total       = peds.length;
      const taxaOTD     = total > 0 ? Math.round(noPrazo / total * 10000) / 100 : 0;

      const dA={}, dD={};
      [1,2,3,4,5].forEach(d => {
        dA[String(d)] = peds.filter(p => p.dias === d).length;
        dD[String(d)] = peds.filter(p => p.dias === -d).length;
      });
      dA["n>5"] = mais5;
      dD["n>5"] = peds.filter(p => p.dias < -5).length;

      // Check and fix each field
      const fields = {
        totalPedidos: total, pedidosNoPrazo: noPrazo, taxaOTD,
        pedidosDataExata: dataExata, pedidosAdiantados: adiantados,
        pedidosAtrasados: atrasados, pedidosAte5DiasAtraso: ate5,
        pedidosMais5DiasAtraso: mais5
      };

      Object.entries(fields).forEach(([k,v]) => {
        if(m[k] !== v){ console.warn(`[${mk}] Corrigindo ${k}: ${m[k]} → ${v}`); m[k] = v; fixed++; }
      });

      // Fix distribuicoes
      Object.entries(dA).forEach(([k,v]) => {
        if((m.distribuicaoAtraso||{})[k] !== v){ if(!m.distribuicaoAtraso)m.distribuicaoAtraso={}; m.distribuicaoAtraso[k]=v; fixed++; }
      });
      Object.entries(dD).forEach(([k,v]) => {
        if((m.distribuicaoAdiantamento||{})[k] !== v){ if(!m.distribuicaoAdiantamento)m.distribuicaoAdiantamento={}; m.distribuicaoAdiantamento[k]=v; fixed++; }
      });

      // Fix individual pedido DIAS if dates available
      peds.forEach(p => {
        if(p.prevEnt && p.dtFat){
          const recalc = calcDias(p.prevEnt, p.dtFat);
          if(recalc !== null && recalc !== p.dias){
            console.warn(`[${mk}] pedido ${p.pedido}: DIAS ${p.dias} → ${recalc} (recalculado de datas)`);
            p.dias = recalc;
            fixed++;
          }
        }
      });
    });

    // Clean up orphan motivoAssignments
    let maFixed = 0;
    try{
      const ma = JSON.parse(localStorage.getItem("motivoAssignments")||"{}");
      const nMotivos = ((window.DASHBOARD_CONFIG&&window.DASHBOARD_CONFIG.otd&&window.DASHBOARD_CONFIG.otd.motivosAtraso)||[]).length;
      const cleaned = {};
      Object.entries(ma).forEach(([key, idx]) => {
        const [mk, pedStr] = key.split(":");
        const pedNum = parseInt(pedStr);
        const monthExists = data.months[mk];
        const pedExists = monthExists && (data.months[mk].pedidos||[]).some(p=>p.pedido===pedNum);
        const idxValid = typeof idx==="number" && idx>=0 && idx<nMotivos;
        if(pedExists && idxValid){ cleaned[key] = idx; }
        else { console.warn(`motivoAssignments: removendo entrada órfã "${key}"`); maFixed++; }
      });
      localStorage.setItem("motivoAssignments", JSON.stringify(cleaned));
    }catch(e){ console.error("Erro ao limpar motivoAssignments:", e); }

    if(fixed > 0 || maFixed > 0){
      console.log(`%c✅ ${fixed} campo(s) corrigido(s) em otdData, ${maFixed} entrada(s) órfã(s) removida(s) de motivoAssignments`, "color:#27AE60;font-weight:bold");
      console.log("Execute exportDataJs() para persistir as correções no data.js.");
    } else {
      console.log("%c✅ Nenhuma correção necessária — dados consistentes.", "color:#27AE60;font-weight:bold");
    }
    return { fixed, maFixed };
  };

  // ─── Expõe helpers para reutilização em outros módulos ──────────────────
  // Permite index.html usar V._parseD e V._calcDias sem duplicar o código.
  V._parseD = parseD;
  V._calcDias = calcDias;

  // ─── Versão silenciosa (sem console.log) ─────────────────────────────────
  // Útil para chamada automática no import: retorna objeto results sem output.
  V.runSilent = function() {
    const saved = { log: console.log, warn: console.warn, error: console.error,
                    info: console.info, group: console.group, groupEnd: console.groupEnd };
    // Não suprime: apenas roda run() normalmente e retorna result sem efeitos
    return V.run();
  };

  // ─── Relatório em HTML (para exibir em modal na UI) ──────────────────────
  // Retorna string HTML com erros, avisos e infos formatados com cores.
  V.toHTML = function() {
    const r = V.run();
    const esc = s => s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
    let html = '<div style="font-family:monospace;font-size:.82rem;line-height:1.7">';

    if (r.errors.length) {
      html += `<div style="margin-bottom:8px"><strong style="color:#EB5757">❌ ERROS (${r.errors.length})</strong><ul style="margin:4px 0 0 0;padding-left:18px">`;
      r.errors.forEach(e => { html += `<li style="color:#c0392b">${esc(e)}</li>`; });
      html += '</ul></div>';
    } else {
      html += '<p style="color:#27AE60;font-weight:700">✅ Nenhum erro encontrado</p>';
    }

    if (r.warnings.length) {
      html += `<div style="margin-bottom:8px"><strong style="color:#F2994A">⚠️ AVISOS (${r.warnings.length})</strong><ul style="margin:4px 0 0 0;padding-left:18px">`;
      r.warnings.forEach(w => { html += `<li style="color:#d35400">${esc(w)}</li>`; });
      html += '</ul></div>';
    }

    html += `<div><strong style="color:#888">ℹ️ INFO</strong><ul style="margin:4px 0 0 0;padding-left:18px;color:#666">`;
    r.info.forEach(i => { html += `<li>${esc(i)}</li>`; });
    html += '</ul></div>';

    html += `<p style="margin-top:10px;font-weight:700;border-top:1px solid #eee;padding-top:8px">`;
    html += `Total: <span style="color:#EB5757">${r.errors.length} erros</span>, `;
    html += `<span style="color:#F2994A">${r.warnings.length} avisos</span></p>`;
    html += '</div>';
    return html;
  };

  // ─── Detecção de duplicatas entre meses ──────────────────────────────────
  // Complementa V.run() que já detecta dentro do mês; este checa entre meses.
  V.runCrossMonthDuplicates = function() {
    const data = window.otdData;
    if (!data || !data.months) return [];
    const seenGlobal = new Set();
    const duplicates = [];
    Object.entries(data.months).forEach(([mk, m]) => {
      (m.pedidos || []).forEach(p => {
        const key = `${p.pedido}-${p.nf}-${p.dtFat}`;
        if (seenGlobal.has(key)) {
          duplicates.push({ mk, pedido: p.pedido, nf: p.nf, dtFat: p.dtFat, key });
        }
        seenGlobal.add(key);
      });
    });
    return duplicates;
  };

  window.OTDValidator = V;
  console.info("✅ OTDValidator carregado. Execute OTDValidator.report() para auditoria completa.");
})(window);
