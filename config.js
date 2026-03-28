(function(window) {
    window.DASHBOARD_CONFIG = window.DASHBOARD_CONFIG || {};

    window.DASHBOARD_CONFIG.otd = {
        metaOTD: 85,
        colors: {
            totalPedidos: '#1a3a6b',
            noPrazo:      '#27AE60',
            adiantados:   '#56CCF2',
            atrasados:    '#EB5757',
            ate5Dias:     '#F2994A',
            mais5Dias:    '#9B1C1C'
        },
        motivosAtraso: [
            'Alinhamentos acordados de forma legítima com clientes',
            'Falta de estoque para cumprir data do pedido',
            'Falta de embalagens (IBC, Tambor, BB, Cilindro)',
            'Cliente se apresentou fora do horário de carregamento (FOB)',
            'Transporte do cliente se apresentou fora dos parâmetros de Segurança',
            'Atraso na logística de carregamento por parte da Usiquímica'
        ],
        // Tiers de SLA em dias: [limite_tier1, limite_tier2, ...]
        // Tier 1: 0 dias (no prazo), Tier 2: 1-3 dias, Tier 3: 4-7 dias, Tier 4: 8+ dias
        slaThresholds: [0, 3, 7],
        // Limites de idade dos dados para alertas de staleness
        staleDataDays: { warning: 3, critical: 8 },
        // Opções de exportação
        exportOptions: {
            csvSeparator: ';',
            bom: true
        },
        // Defaults visuais para Chart.js
        chartDefaults: {
            borderRadius: 8,
            yAxisStepSize: 50
        }
    };
})(window);
