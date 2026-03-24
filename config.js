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
        ]
    };
})(window);
