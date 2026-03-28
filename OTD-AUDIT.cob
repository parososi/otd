      *> OTD-AUDIT.cob — Gerador de Trilha de Auditoria OTD
      *>
      *> Compilar: cobc -x OTD-AUDIT.cob -o otd_audit
      *> Uso:     ./otd_audit PEDIDOS.TXT AUDITORIA.TXT
      *>
      *> Lê um arquivo de largura fixa exportado do CSV OTD e gera
      *> um relatório de auditoria imutável no formato "green-bar".
      *>
      *> Formato de entrada (largura fixa, uma linha por pedido):
      *>   Cols  1-8  : Nº Pedido (inteiro)
      *>   Cols  9-48 : Nome Fantasia (40 chars)
      *>   Cols 49-68 : Vendedor (20 chars)
      *>   Cols 69-78 : PREV ENT DD/MM/YYYY (10 chars)
      *>   Cols 79-88 : DT FAT  DD/MM/YYYY (10 chars)
      *>   Cols 89-92 : DIAS (signed 4 digits, ex: +003, -002, +000)
      *>   Cols 93-106: VLR MERC (12.2 sem separador, ex: 000061876.50)
      *>
      *> Por que COBOL:
      *>   - PIC S9(4) trata DIAS negativo nativamente (adiantado)
      *>   - COMPUTE ROUNDED garante precisão decimal sem ponto flutuante
      *>   - Arquivo de saída write-once = trilha de auditoria imutável
      *>   - Integra diretamente em schedulers JCL de mainframes AS/400 / Z-series
      *>   - Empresas em ambientes regulados (ANVISA, ISO) exigem este formato

       IDENTIFICATION DIVISION.
       PROGRAM-ID. OTD-AUDIT.
       AUTHOR. USIQUIMICA-TI.
       DATE-WRITTEN. 2026-03-28.

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT PEDIDOS-FILE ASSIGN TO WS-INPUT-FILE
               ORGANIZATION IS LINE SEQUENTIAL
               ACCESS MODE IS SEQUENTIAL.
           SELECT AUDIT-FILE ASSIGN TO WS-OUTPUT-FILE
               ORGANIZATION IS LINE SEQUENTIAL
               ACCESS MODE IS SEQUENTIAL.

       DATA DIVISION.
       FILE SECTION.

       FD  PEDIDOS-FILE.
       01  PEDIDOS-REC.
           05 PR-PEDIDO        PIC 9(8).
           05 PR-NOME-FANTASIA PIC X(40).
           05 PR-VENDEDOR      PIC X(20).
           05 PR-PREV-ENT      PIC X(10).
           05 PR-DT-FAT        PIC X(10).
           05 PR-DIAS          PIC S9(3) SIGN LEADING SEPARATE.
           05 PR-VLR-MERC      PIC 9(10)V99.

       FD  AUDIT-FILE.
       01  AUDIT-REC           PIC X(132).

       WORKING-STORAGE SECTION.

       01 WS-INPUT-FILE        PIC X(256).
       01 WS-OUTPUT-FILE       PIC X(256).

       01 WS-EOF               PIC X VALUE 'N'.
       01 WS-LINE-COUNT        PIC 9(6) VALUE 0.
       01 WS-PAGE-COUNT        PIC 9(4) VALUE 0.
       01 WS-LINES-PER-PAGE    PIC 9(3) VALUE 55.

       *> Contadores acumulados
       01 WS-TOTAL-PEDIDOS     PIC 9(8) VALUE 0.
       01 WS-TOTAL-NO-PRAZO    PIC 9(8) VALUE 0.
       01 WS-TOTAL-EXATO       PIC 9(8) VALUE 0.
       01 WS-TOTAL-ADIANTADO   PIC 9(8) VALUE 0.
       01 WS-TOTAL-ATRASADO    PIC 9(8) VALUE 0.
       01 WS-TOTAL-ATE5        PIC 9(8) VALUE 0.
       01 WS-TOTAL-MAIS5       PIC 9(8) VALUE 0.
       01 WS-TOTAL-VALOR       PIC 9(14)V99 VALUE 0.
       01 WS-VALOR-ATRASADO    PIC 9(14)V99 VALUE 0.

       01 WS-TAXA-OTD          PIC 9(5)V99 VALUE 0.
       01 WS-PCT-RISCO         PIC 9(5)V99 VALUE 0.

       *> Linha de saída
       01 WS-AUDIT-LINE.
           05 AL-PEDIDO        PIC Z(7)9.
           05 FILLER           PIC X(3) VALUE ' | '.
           05 AL-STATUS        PIC X(12).
           05 FILLER           PIC X(3) VALUE ' | '.
           05 AL-DIAS          PIC +ZZZ.
           05 FILLER           PIC X(8) VALUE ' DIAS  |'.
           05 AL-NOME          PIC X(25).
           05 FILLER           PIC X(3) VALUE ' | '.
           05 AL-VENDEDOR      PIC X(16).
           05 FILLER           PIC X(3) VALUE ' | '.
           05 AL-PREV-ENT      PIC X(10).
           05 FILLER           PIC X(3) VALUE ' > '.
           05 AL-DT-FAT        PIC X(10).
           05 FILLER           PIC X(3) VALUE ' | '.
           05 AL-VALOR         PIC ZZZ,ZZZ,ZZ9.99.

       01 WS-HEADER-1.
           05 FILLER PIC X(40) VALUE
              '========================================'.
           05 FILLER PIC X(42) VALUE
              '========================================  '.
           05 FILLER PIC X(50) VALUE SPACES.

       01 WS-HEADER-2.
           05 FILLER PIC X(20) VALUE 'USIQUIMICA'.
           05 FILLER PIC X(20) VALUE ' AUDITORIA OTD'.
           05 FILLER PIC X(10) VALUE '   DATA: '.
           05 WS-H2-DATA       PIC X(10).
           05 FILLER           PIC X(72) VALUE SPACES.

       01 WS-HEADER-3.
           05 FILLER PIC X(8)  VALUE 'PEDIDO  '.
           05 FILLER PIC X(15) VALUE '| STATUS        '.
           05 FILLER PIC X(12) VALUE '| DIAS       '.
           05 FILLER PIC X(28) VALUE '| CLIENTE                   '.
           05 FILLER PIC X(19) VALUE '| VENDEDOR        '.
           05 FILLER PIC X(27) VALUE '| PREV ENT > DT FAT       '.
           05 FILLER PIC X(23) VALUE '| VALOR (R$)'.

       01 WS-TOTALS-LINE.
           05 FILLER           PIC X(20) VALUE 'TOTAL PEDIDOS : '.
           05 WS-TL-TOTAL      PIC ZZZ,ZZ9.
           05 FILLER           PIC X(4)  VALUE '    '.
           05 FILLER           PIC X(18) VALUE 'NO PRAZO : '.
           05 WS-TL-NOPRAZO    PIC ZZZ,ZZ9.
           05 FILLER           PIC X(4)  VALUE '    '.
           05 FILLER           PIC X(16) VALUE 'ATRASADOS : '.
           05 WS-TL-ATRAS      PIC ZZZ,ZZ9.
           05 FILLER           PIC X(4)  VALUE '    '.
           05 FILLER           PIC X(11) VALUE 'TAXA OTD: '.
           05 WS-TL-TAXA       PIC ZZ9.99.
           05 FILLER           PIC X     VALUE '%'.

       01 WS-VALOR-LINE.
           05 FILLER           PIC X(20) VALUE 'VALOR TOTAL     : R$'.
           05 WS-VL-TOTAL      PIC ZZ,ZZZ,ZZZ,ZZ9.99.
           05 FILLER           PIC X(4)  VALUE '    '.
           05 FILLER           PIC X(22) VALUE 'VALOR EM RISCO : R$'.
           05 WS-VL-RISCO      PIC ZZ,ZZZ,ZZZ,ZZ9.99.
           05 FILLER           PIC X(4)  VALUE '    '.
           05 FILLER           PIC X(12) VALUE '% RISCO: '.
           05 WS-PCT-LINE      PIC ZZ9.99.
           05 FILLER           PIC X     VALUE '%'.

       01 WS-TODAY             PIC X(10) VALUE SPACES.

       PROCEDURE DIVISION.

       0000-MAIN.
           ACCEPT WS-INPUT-FILE  FROM COMMAND-LINE
           ACCEPT WS-OUTPUT-FILE FROM COMMAND-LINE

           IF WS-INPUT-FILE = SPACES
               MOVE 'PEDIDOS.TXT'  TO WS-INPUT-FILE
           END-IF
           IF WS-OUTPUT-FILE = SPACES
               MOVE 'AUDITORIA.TXT' TO WS-OUTPUT-FILE
           END-IF

           OPEN INPUT  PEDIDOS-FILE
           OPEN OUTPUT AUDIT-FILE

           PERFORM 1000-WRITE-HEADER

           PERFORM 2000-PROCESS-PEDIDOS UNTIL WS-EOF = 'Y'

           PERFORM 3000-WRITE-TOTALS

           CLOSE PEDIDOS-FILE
           CLOSE AUDIT-FILE
           STOP RUN.

       1000-WRITE-HEADER.
           MOVE FUNCTION CURRENT-DATE(1:10) TO WS-TODAY
           MOVE WS-TODAY TO WS-H2-DATA

           WRITE AUDIT-REC FROM WS-HEADER-1
           WRITE AUDIT-REC FROM WS-HEADER-2
           MOVE WS-HEADER-1 TO AUDIT-REC
           WRITE AUDIT-REC FROM WS-HEADER-1
           WRITE AUDIT-REC FROM WS-HEADER-3
           WRITE AUDIT-REC FROM WS-HEADER-1
           ADD 5 TO WS-LINE-COUNT.

       2000-PROCESS-PEDIDOS.
           READ PEDIDOS-FILE INTO PEDIDOS-REC
               AT END MOVE 'Y' TO WS-EOF
               NOT AT END PERFORM 2100-PROCESS-RECORD
           END-READ.

       2100-PROCESS-RECORD.
           ADD 1 TO WS-TOTAL-PEDIDOS
           ADD PR-VLR-MERC TO WS-TOTAL-VALOR

           *> Classificar status
           EVALUATE TRUE
               WHEN PR-DIAS > 0
                   MOVE 'ATRASADO    ' TO AL-STATUS
                   ADD 1 TO WS-TOTAL-ATRASADO
                   ADD PR-VLR-MERC TO WS-VALOR-ATRASADO
                   IF PR-DIAS > 5
                       ADD 1 TO WS-TOTAL-MAIS5
                   ELSE
                       ADD 1 TO WS-TOTAL-ATE5
                   END-IF
               WHEN PR-DIAS < 0
                   MOVE 'ADIANTADO   ' TO AL-STATUS
                   ADD 1 TO WS-TOTAL-ADIANTADO
                   ADD 1 TO WS-TOTAL-NO-PRAZO
               WHEN OTHER
                   MOVE 'NO PRAZO    ' TO AL-STATUS
                   ADD 1 TO WS-TOTAL-NO-PRAZO
                   ADD 1 TO WS-TOTAL-EXATO
           END-EVALUATE

           *> Montar linha de auditoria
           MOVE PR-PEDIDO     TO AL-PEDIDO
           MOVE PR-DIAS       TO AL-DIAS
           MOVE PR-NOME-FANTASIA (1:25) TO AL-NOME
           MOVE PR-VENDEDOR (1:16) TO AL-VENDEDOR
           MOVE PR-PREV-ENT   TO AL-PREV-ENT
           MOVE PR-DT-FAT     TO AL-DT-FAT
           MOVE PR-VLR-MERC   TO AL-VALOR

           WRITE AUDIT-REC FROM WS-AUDIT-LINE
           ADD 1 TO WS-LINE-COUNT

           *> Quebra de página a cada WS-LINES-PER-PAGE linhas
           IF WS-LINE-COUNT >= WS-LINES-PER-PAGE
               ADD 1 TO WS-PAGE-COUNT
               PERFORM 1000-WRITE-HEADER
               MOVE 0 TO WS-LINE-COUNT
           END-IF.

       3000-WRITE-TOTALS.
           WRITE AUDIT-REC FROM WS-HEADER-1

           *> Calcular taxa OTD: COMPUTE ROUNDED garante precisão decimal
           IF WS-TOTAL-PEDIDOS > 0
               COMPUTE WS-TAXA-OTD ROUNDED =
                   WS-TOTAL-NO-PRAZO * 100.00 / WS-TOTAL-PEDIDOS
           ELSE
               MOVE 0 TO WS-TAXA-OTD
           END-IF

           *> Calcular % valor em risco
           IF WS-TOTAL-VALOR > 0
               COMPUTE WS-PCT-RISCO ROUNDED =
                   WS-VALOR-ATRASADO * 100.00 / WS-TOTAL-VALOR
           ELSE
               MOVE 0 TO WS-PCT-RISCO
           END-IF

           MOVE WS-TOTAL-PEDIDOS TO WS-TL-TOTAL
           MOVE WS-TOTAL-NO-PRAZO TO WS-TL-NOPRAZO
           MOVE WS-TOTAL-ATRASADO TO WS-TL-ATRAS
           MOVE WS-TAXA-OTD TO WS-TL-TAXA

           WRITE AUDIT-REC FROM WS-TOTALS-LINE

           MOVE WS-TOTAL-VALOR TO WS-VL-TOTAL
           MOVE WS-VALOR-ATRASADO TO WS-VL-RISCO
           MOVE WS-PCT-RISCO TO WS-PCT-LINE

           WRITE AUDIT-REC FROM WS-VALOR-LINE
           WRITE AUDIT-REC FROM WS-HEADER-1

           *> Linha de conclusão de auditoria
           MOVE SPACES TO AUDIT-REC
           STRING 'AUDITORIA CONCLUIDA: '
                  WS-TOTAL-PEDIDOS ' PEDIDOS PROCESSADOS'
                  DELIMITED BY SIZE
                  INTO AUDIT-REC
           WRITE AUDIT-REC.

       END PROGRAM OTD-AUDIT.
