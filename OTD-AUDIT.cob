      *> OTD-AUDIT.cob — Gerador de Trilha de Auditoria OTD
      *>
      *> Compilar: cobc -x OTD-AUDIT.cob -o otd_audit
      *> Uso:     ./otd_audit < PEDIDOS.TXT > AUDITORIA.TXT
      *>
      *> Lê registros semicolon-delimited de STDIN e gera
      *> um relatório de auditoria imutável no formato "green-bar"
      *> para STDOUT.
      *>
      *> Formato de entrada (CSV com ; separador, via STDIN):
      *>   Campo 1: Nº Pedido (inteiro)
      *>   Campo 2: Nome Fantasia (texto)
      *>   Campo 3: Vendedor (texto)
      *>   Campo 4: PREV ENT DD/MM/YYYY
      *>   Campo 5: DT FAT  DD/MM/YYYY
      *>   Campo 6: DIAS (inteiro com sinal, ex: +3, -2, 0)
      *>   Campo 7: VLR MERC (decimal, ex: 61876.50)
      *>
      *> Por que COBOL:
      *>   - PIC S9(4) trata DIAS negativo nativamente
      *>   - COMPUTE ROUNDED garante precisão decimal sem float
      *>   - Saída write-once = trilha de auditoria imutável
      *>   - Integra em schedulers JCL de mainframes AS/400

       IDENTIFICATION DIVISION.
       PROGRAM-ID. OTD-AUDIT.
       AUTHOR. USIQUIMICA-TI.
       DATE-WRITTEN. 2026-03-28.

       DATA DIVISION.
       WORKING-STORAGE SECTION.

       01 WS-INPUT-LINE         PIC X(512).
       01 WS-EOF                PIC X VALUE 'N'.
       01 WS-LINE-COUNT         PIC 9(6) VALUE 0.
       01 WS-PAGE-COUNT         PIC 9(4) VALUE 0.
       01 WS-LINES-PER-PAGE     PIC 9(3) VALUE 55.

      *> Campos parseados da linha CSV
       01 WS-FIELD-1            PIC X(12).
       01 WS-FIELD-2            PIC X(40).
       01 WS-FIELD-3            PIC X(20).
       01 WS-FIELD-4            PIC X(10).
       01 WS-FIELD-5            PIC X(10).
       01 WS-FIELD-6            PIC X(8).
       01 WS-FIELD-7            PIC X(16).

      *> Campos convertidos
       01 WS-PEDIDO             PIC 9(8) VALUE 0.
       01 WS-NOME-FANTASIA      PIC X(40).
       01 WS-VENDEDOR           PIC X(20).
       01 WS-PREV-ENT           PIC X(10).
       01 WS-DT-FAT             PIC X(10).
       01 WS-DIAS               PIC S9(4) VALUE 0.
       01 WS-VLR-MERC           PIC 9(10)V99 VALUE 0.

      *> Parser helpers
       01 WS-POS                PIC 9(4).
       01 WS-START              PIC 9(4).
       01 WS-LEN                PIC 9(4).
       01 WS-FIELD-NUM          PIC 9(2).
       01 WS-CHAR               PIC X.
       01 WS-INPUT-LEN          PIC 9(4).
       01 WS-TEMP-FIELD         PIC X(80).

      *> Contadores acumulados
       01 WS-TOTAL-PEDIDOS      PIC 9(8) VALUE 0.
       01 WS-TOTAL-NO-PRAZO     PIC 9(8) VALUE 0.
       01 WS-TOTAL-EXATO        PIC 9(8) VALUE 0.
       01 WS-TOTAL-ADIANTADO    PIC 9(8) VALUE 0.
       01 WS-TOTAL-ATRASADO     PIC 9(8) VALUE 0.
       01 WS-TOTAL-ATE5         PIC 9(8) VALUE 0.
       01 WS-TOTAL-MAIS5        PIC 9(8) VALUE 0.
       01 WS-TOTAL-VALOR        PIC 9(14)V99 VALUE 0.
       01 WS-VALOR-ATRASADO     PIC 9(14)V99 VALUE 0.

       01 WS-TAXA-OTD           PIC 9(5)V99 VALUE 0.
       01 WS-PCT-RISCO          PIC 9(5)V99 VALUE 0.

      *> Linha de saída
       01 WS-AUDIT-LINE.
           05 AL-PEDIDO         PIC Z(7)9.
           05 FILLER            PIC X(3) VALUE ' | '.
           05 AL-STATUS         PIC X(12).
           05 FILLER            PIC X(3) VALUE ' | '.
           05 AL-DIAS           PIC +ZZZ.
           05 FILLER            PIC X(8) VALUE ' DIAS  |'.
           05 AL-NOME           PIC X(25).
           05 FILLER            PIC X(3) VALUE ' | '.
           05 AL-VENDEDOR       PIC X(16).
           05 FILLER            PIC X(3) VALUE ' | '.
           05 AL-PREV-ENT       PIC X(10).
           05 FILLER            PIC X(3) VALUE ' > '.
           05 AL-DT-FAT         PIC X(10).
           05 FILLER            PIC X(3) VALUE ' | '.
           05 AL-VALOR          PIC ZZZ,ZZZ,ZZ9.99.

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
           05 WS-H2-DATA        PIC X(10).
           05 FILLER            PIC X(72) VALUE SPACES.

       01 WS-HEADER-3.
           05 FILLER PIC X(8)  VALUE 'PEDIDO  '.
           05 FILLER PIC X(15) VALUE '| STATUS        '.
           05 FILLER PIC X(12) VALUE '| DIAS       '.
           05 FILLER PIC X(28) VALUE '| CLIENTE                   '.
           05 FILLER PIC X(19) VALUE '| VENDEDOR        '.
           05 FILLER PIC X(27) VALUE '| PREV ENT > DT FAT       '.
           05 FILLER PIC X(23) VALUE '| VALOR (R$)'.

       01 WS-TOTALS-LINE.
           05 FILLER            PIC X(20) VALUE 'TOTAL PEDIDOS : '.
           05 WS-TL-TOTAL       PIC ZZZ,ZZ9.
           05 FILLER            PIC X(4)  VALUE '    '.
           05 FILLER            PIC X(18) VALUE 'NO PRAZO : '.
           05 WS-TL-NOPRAZO     PIC ZZZ,ZZ9.
           05 FILLER            PIC X(4)  VALUE '    '.
           05 FILLER            PIC X(16) VALUE 'ATRASADOS : '.
           05 WS-TL-ATRAS       PIC ZZZ,ZZ9.
           05 FILLER            PIC X(4)  VALUE '    '.
           05 FILLER            PIC X(11) VALUE 'TAXA OTD: '.
           05 WS-TL-TAXA        PIC ZZ9.99.
           05 FILLER            PIC X     VALUE '%'.

       01 WS-VALOR-LINE.
           05 FILLER            PIC X(20) VALUE 'VALOR TOTAL     : R$'.
           05 WS-VL-TOTAL       PIC ZZ,ZZZ,ZZZ,ZZ9.99.
           05 FILLER            PIC X(4)  VALUE '    '.
           05 FILLER            PIC X(22) VALUE 'VALOR EM RISCO : R$'.
           05 WS-VL-RISCO       PIC ZZ,ZZZ,ZZZ,ZZ9.99.
           05 FILLER            PIC X(4)  VALUE '    '.
           05 FILLER            PIC X(12) VALUE '% RISCO: '.
           05 WS-PCT-LINE       PIC ZZ9.99.
           05 FILLER            PIC X     VALUE '%'.

       01 WS-TODAY              PIC X(10) VALUE SPACES.

       01 WS-OUTPUT-LINE        PIC X(132).
       01 WS-CONCLUSION-LINE    PIC X(132).

       PROCEDURE DIVISION.

       0000-MAIN.
           MOVE FUNCTION CURRENT-DATE(7:2) TO WS-TODAY(1:2)
           MOVE '/'                        TO WS-TODAY(3:1)
           MOVE FUNCTION CURRENT-DATE(5:2) TO WS-TODAY(4:2)
           MOVE '/'                        TO WS-TODAY(6:1)
           MOVE FUNCTION CURRENT-DATE(1:4) TO WS-TODAY(7:4)

           PERFORM 1000-WRITE-HEADER

           PERFORM 2000-READ-AND-PROCESS UNTIL WS-EOF = 'Y'

           PERFORM 3000-WRITE-TOTALS

           STOP RUN.

       1000-WRITE-HEADER.
           MOVE WS-TODAY TO WS-H2-DATA
           DISPLAY WS-HEADER-1
           DISPLAY WS-HEADER-2
           DISPLAY WS-HEADER-1
           DISPLAY WS-HEADER-3
           DISPLAY WS-HEADER-1
           ADD 5 TO WS-LINE-COUNT.

       2000-READ-AND-PROCESS.
           ACCEPT WS-INPUT-LINE FROM STANDARD-INPUT
               ON EXCEPTION
                   MOVE 'Y' TO WS-EOF
               NOT ON EXCEPTION
                   IF WS-INPUT-LINE = SPACES
                       MOVE 'Y' TO WS-EOF
                   ELSE
                       PERFORM 2100-PARSE-CSV-LINE
                       PERFORM 2200-PROCESS-RECORD
                   END-IF
           END-ACCEPT.

       2100-PARSE-CSV-LINE.
      *>   Parseia linha CSV separada por ';' em 7 campos
           MOVE SPACES TO WS-FIELD-1 WS-FIELD-2 WS-FIELD-3
                          WS-FIELD-4 WS-FIELD-5 WS-FIELD-6
                          WS-FIELD-7
           MOVE 1 TO WS-POS
           MOVE 1 TO WS-FIELD-NUM
           MOVE FUNCTION LENGTH(FUNCTION TRIM(
               WS-INPUT-LINE TRAILING))
               TO WS-INPUT-LEN

           PERFORM 2110-EXTRACT-FIELDS
               VARYING WS-FIELD-NUM FROM 1 BY 1
               UNTIL WS-FIELD-NUM > 7 OR WS-POS > WS-INPUT-LEN

      *>   Converter campos para variáveis tipadas
           MOVE FUNCTION TRIM(WS-FIELD-1) TO WS-PEDIDO
           MOVE WS-FIELD-2 TO WS-NOME-FANTASIA
           MOVE WS-FIELD-3 TO WS-VENDEDOR
           MOVE WS-FIELD-4 TO WS-PREV-ENT
           MOVE WS-FIELD-5 TO WS-DT-FAT
           MOVE FUNCTION NUMVAL(FUNCTION TRIM(WS-FIELD-6))
               TO WS-DIAS
           MOVE FUNCTION NUMVAL(FUNCTION TRIM(WS-FIELD-7))
               TO WS-VLR-MERC.

       2110-EXTRACT-FIELDS.
           MOVE WS-POS TO WS-START
           MOVE SPACES TO WS-TEMP-FIELD

      *>   Avança até ';' ou fim da linha
           PERFORM UNTIL WS-POS > WS-INPUT-LEN
               MOVE WS-INPUT-LINE(WS-POS:1) TO WS-CHAR
               IF WS-CHAR = ';'
                   EXIT PERFORM
               END-IF
               ADD 1 TO WS-POS
           END-PERFORM

      *>   Extrai campo
           IF WS-POS > WS-START
               COMPUTE WS-LEN = WS-POS - WS-START
               MOVE WS-INPUT-LINE(WS-START:WS-LEN)
                   TO WS-TEMP-FIELD
           END-IF

      *>   Pula o ';'
           ADD 1 TO WS-POS

      *>   Atribui ao campo correto
           EVALUATE WS-FIELD-NUM
               WHEN 1 MOVE WS-TEMP-FIELD TO WS-FIELD-1
               WHEN 2 MOVE WS-TEMP-FIELD TO WS-FIELD-2
               WHEN 3 MOVE WS-TEMP-FIELD TO WS-FIELD-3
               WHEN 4 MOVE WS-TEMP-FIELD TO WS-FIELD-4
               WHEN 5 MOVE WS-TEMP-FIELD TO WS-FIELD-5
               WHEN 6 MOVE WS-TEMP-FIELD TO WS-FIELD-6
               WHEN 7 MOVE WS-TEMP-FIELD TO WS-FIELD-7
           END-EVALUATE.

       2200-PROCESS-RECORD.
           ADD 1 TO WS-TOTAL-PEDIDOS
           ADD WS-VLR-MERC TO WS-TOTAL-VALOR

      *>   Classificar status
           EVALUATE TRUE
               WHEN WS-DIAS > 0
                   MOVE 'ATRASADO    ' TO AL-STATUS
                   ADD 1 TO WS-TOTAL-ATRASADO
                   ADD WS-VLR-MERC TO WS-VALOR-ATRASADO
                   IF WS-DIAS > 5
                       ADD 1 TO WS-TOTAL-MAIS5
                   ELSE
                       ADD 1 TO WS-TOTAL-ATE5
                   END-IF
               WHEN WS-DIAS < 0
                   MOVE 'ADIANTADO   ' TO AL-STATUS
                   ADD 1 TO WS-TOTAL-ADIANTADO
                   ADD 1 TO WS-TOTAL-NO-PRAZO
               WHEN OTHER
                   MOVE 'NO PRAZO    ' TO AL-STATUS
                   ADD 1 TO WS-TOTAL-NO-PRAZO
                   ADD 1 TO WS-TOTAL-EXATO
           END-EVALUATE

      *>   Montar linha de auditoria
           MOVE WS-PEDIDO               TO AL-PEDIDO
           MOVE WS-DIAS                 TO AL-DIAS
           MOVE WS-NOME-FANTASIA(1:25)  TO AL-NOME
           MOVE WS-VENDEDOR(1:16)       TO AL-VENDEDOR
           MOVE WS-PREV-ENT             TO AL-PREV-ENT
           MOVE WS-DT-FAT               TO AL-DT-FAT
           MOVE WS-VLR-MERC             TO AL-VALOR

           DISPLAY WS-AUDIT-LINE
           ADD 1 TO WS-LINE-COUNT

      *>   Quebra de página a cada WS-LINES-PER-PAGE linhas
           IF WS-LINE-COUNT >= WS-LINES-PER-PAGE
               ADD 1 TO WS-PAGE-COUNT
               PERFORM 1000-WRITE-HEADER
               MOVE 0 TO WS-LINE-COUNT
           END-IF.

       3000-WRITE-TOTALS.
           DISPLAY WS-HEADER-1

      *>   Calcular taxa OTD
           IF WS-TOTAL-PEDIDOS > 0
               COMPUTE WS-TAXA-OTD ROUNDED =
                   WS-TOTAL-NO-PRAZO * 100.00 / WS-TOTAL-PEDIDOS
           ELSE
               MOVE 0 TO WS-TAXA-OTD
           END-IF

      *>   Calcular % valor em risco
           IF WS-TOTAL-VALOR > 0
               COMPUTE WS-PCT-RISCO ROUNDED =
                   WS-VALOR-ATRASADO * 100.00 / WS-TOTAL-VALOR
           ELSE
               MOVE 0 TO WS-PCT-RISCO
           END-IF

           MOVE WS-TOTAL-PEDIDOS  TO WS-TL-TOTAL
           MOVE WS-TOTAL-NO-PRAZO TO WS-TL-NOPRAZO
           MOVE WS-TOTAL-ATRASADO TO WS-TL-ATRAS
           MOVE WS-TAXA-OTD       TO WS-TL-TAXA

           DISPLAY WS-TOTALS-LINE

           MOVE WS-TOTAL-VALOR    TO WS-VL-TOTAL
           MOVE WS-VALOR-ATRASADO TO WS-VL-RISCO
           MOVE WS-PCT-RISCO      TO WS-PCT-LINE

           DISPLAY WS-VALOR-LINE
           DISPLAY WS-HEADER-1

      *>   Linha de conclusão
           MOVE SPACES TO WS-CONCLUSION-LINE
           STRING 'AUDITORIA CONCLUIDA: '
                  WS-TOTAL-PEDIDOS ' PEDIDOS PROCESSADOS'
                  DELIMITED BY SIZE
                  INTO WS-CONCLUSION-LINE
           DISPLAY WS-CONCLUSION-LINE.

       END PROGRAM OTD-AUDIT.
