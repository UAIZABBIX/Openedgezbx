/*------------------------------------------------------------------------
   File        : openedgezbx.p
   Purpose     : Coletor de métricas Progress OpenEdge RDBMS para Zabbix
   Syntax      : mpro /caminho/banco -ld NOMELOGICO -b -q -p openedgezbx.p
                 _progres /caminho/banco -ld NOMELOGICO -b -q -p openedgezbx.p
   Description : Programa em modo batch que se conecta ao banco Progress
                 já disponibilizado em runtime, identifica nome lógico e
                 físico, consulta as VSTs (Virtual System Tables), coleta
                 métricas de saúde, desempenho, I/O, memória, transações,
                 bloqueios, conectividade e configuração, calcula valores
                 derivados quando necessário e emite o resultado como um
                 único JSON estruturado, válido e parseável via STDOUT,
                 sem gerar arquivos intermediários.

                 O JSON é apropriado para consumo por Zabbix, scripts
                 shell, automações de monitoramento e ferramentas de
                 observabilidade externas.

   Compatível  : Progress OpenEdge 12.2
   Author      : openedgezbx collector
   Version     : 1.0.0
   Notes       : - Todas as consultas a VSTs usam NO-LOCK.
                 - Cada bloco de coleta é resiliente: a falha em uma
                   métrica não impede o retorno das demais.
                 - Quando uma métrica não puder ser obtida, retorna-se
                   "value": null e o motivo é registrado no campo
                   "observation" da própria métrica e/ou no array
                   "errors" da raiz do JSON.
                 - Métricas que dependem de baseline temporal externo
                   ou logs externos são marcadas como "unknown" e
                   devidamente documentadas em "observation".
  ----------------------------------------------------------------------*/

/* Diretiva de bloco: mantém comportamento previsível em ON ERROR */
BLOCK-LEVEL ON ERROR UNDO, THROW.

/* ====================================================================
   CONSTANTES DO COLETOR
   ==================================================================== */
&SCOPED-DEFINE COLLECTOR_NAME    "openedgezbx"
&SCOPED-DEFINE COLLECTOR_VERSION "1.1.0"
&SCOPED-DEFINE COLLECTOR_LANG    "Progress ABL"

/* ====================================================================
   VARIÁVEIS GLOBAIS
   --------------------------------------------------------------------
   Mantemos estado global para o JSON que será montado em memória
   (LONGCHAR), os contadores de erros/avisos e a identificação do
   banco. Não usamos arquivos temporários: todo o JSON é construído
   in-memory e emitido via PUT UNFORMATTED para o STDOUT no final.
   ==================================================================== */

DEFINE VARIABLE gcJson         AS LONGCHAR  NO-UNDO.
DEFINE VARIABLE gcErrorsJson   AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE giErrorCount   AS INTEGER   NO-UNDO INITIAL 0.
DEFINE VARIABLE giWarningCount AS INTEGER   NO-UNDO INITIAL 0.
DEFINE VARIABLE gcCollectStat  AS CHARACTER NO-UNDO INITIAL "ok".
DEFINE VARIABLE gcHealthStat   AS CHARACTER NO-UNDO INITIAL "healthy".

/* Identificação do banco descoberta em runtime */
DEFINE VARIABLE gcLogicalName  AS CHARACTER NO-UNDO INITIAL "".
DEFINE VARIABLE gcPhysicalName AS CHARACTER NO-UNDO INITIAL "".
DEFINE VARIABLE gcPhysicalPath AS CHARACTER NO-UNDO INITIAL "".
DEFINE VARIABLE gcHost         AS CHARACTER NO-UNDO INITIAL "".
DEFINE VARIABLE gcDbVersion    AS CHARACTER NO-UNDO INITIAL "".
DEFINE VARIABLE giPid          AS INTEGER   NO-UNDO INITIAL 0.
DEFINE VARIABLE gcDbStatus     AS CHARACTER NO-UNDO INITIAL "online".
DEFINE VARIABLE giActConnects  AS INTEGER   NO-UNDO INITIAL 0.

/* Tempo do banco para cálculos de taxa (per second / per minute) */
DEFINE VARIABLE gdtNow         AS DATETIME  NO-UNDO.
DEFINE VARIABLE gdtStartTime   AS DATETIME  NO-UNDO.
DEFINE VARIABLE gdUptimeSec    AS DECIMAL   NO-UNDO INITIAL 1.

/* Modo debug: quando TRUE, cada métrica inclui unit, status,
   warning_threshold, critical_threshold, source e observation.
   Quando FALSE (padrão), cada métrica retorna apenas "nome": valor.
   Ativação via: mpro ... -p openedgezbx.p -param "debug=true" */
DEFINE VARIABLE glDebug        AS LOGICAL   NO-UNDO INITIAL FALSE.

/* Parâmetros de startup parseados do DBPARAM */
DEFINE VARIABLE giParamB       AS INT64     NO-UNDO INITIAL ?.
DEFINE VARIABLE giParamL       AS INT64     NO-UNDO INITIAL ?.
DEFINE VARIABLE giParamN       AS INT64     NO-UNDO INITIAL ?.
DEFINE VARIABLE giParamSpin    AS INT64     NO-UNDO INITIAL ?.
DEFINE VARIABLE giParamBi      AS INT64     NO-UNDO INITIAL ?.
DEFINE VARIABLE giParamB1      AS INT64     NO-UNDO INITIAL ?.

/* Caracteres especiais para montagem segura de JSON.
   Inicializados no MAIN-BLOCK antes de qualquer coleta.
   - gcQ  = CHR(34) aspas duplas — porque ~" não funciona em OE 12.2
   - gcLB = CHR(123) chave aberta { — porque { em literal de string
     é interpretado como include pelo preprocessador ABL
   - gcRB = CHR(125) chave fechada } */
DEFINE VARIABLE gcQ            AS CHARACTER NO-UNDO.
DEFINE VARIABLE gcLB           AS CHARACTER NO-UNDO.
DEFINE VARIABLE gcRB           AS CHARACTER NO-UNDO.

/* Buffers temporários por seção */
DEFINE VARIABLE gcSecIO        AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecMem       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecTrx       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecLck       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecCon       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecSvc       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecCfg       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecLic       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecSrv       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecBkp       AS LONGCHAR  NO-UNDO INITIAL "".
DEFINE VARIABLE gcSecStg       AS LONGCHAR  NO-UNDO INITIAL "".


/* ====================================================================
   FUNÇÕES AUXILIARES — MANIPULAÇÃO E FORMATAÇÃO JSON
   ==================================================================== */

/*------------------------------------------------------------------
  fnEscape: escapa caracteres especiais para serialização JSON.
  Trata: backslash, aspas, CR, LF, TAB, BS e FF.
 -----------------------------------------------------------------*/
FUNCTION fnEscape RETURNS CHARACTER
    (INPUT pcVal AS CHARACTER) FORWARD.

/*------------------------------------------------------------------
  fnJsonStr: retorna o literal JSON correspondente a uma string.
  Strings vazias ou desconhecidas (?) viram "null" no JSON.
 -----------------------------------------------------------------*/
FUNCTION fnJsonStr RETURNS CHARACTER
    (INPUT pcVal AS CHARACTER) FORWARD.

/*------------------------------------------------------------------
  fnJsonNum: serializa um decimal como número JSON. Garante o ponto
  como separador decimal independentemente do locale do servidor.
 -----------------------------------------------------------------*/
FUNCTION fnJsonNum RETURNS CHARACTER
    (INPUT pdVal AS DECIMAL) FORWARD.

/*------------------------------------------------------------------
  fnJsonInt: serializa um INT64 como número JSON.
 -----------------------------------------------------------------*/
FUNCTION fnJsonInt RETURNS CHARACTER
    (INPUT piVal AS INT64) FORWARD.

/*------------------------------------------------------------------
  fnRound2: arredonda decimal para 2 casas, preservando o unknown.
 -----------------------------------------------------------------*/
FUNCTION fnRound2 RETURNS DECIMAL
    (INPUT pdVal AS DECIMAL) FORWARD.

/*------------------------------------------------------------------
  fnDivSafe: divisão protegida contra zero/null.
 -----------------------------------------------------------------*/
FUNCTION fnDivSafe RETURNS DECIMAL
    (INPUT pdNum AS DECIMAL, INPUT pdDen AS DECIMAL) FORWARD.

/*------------------------------------------------------------------
  fnMetric: monta o fragmento JSON completo de uma métrica no
  formato canônico do coletor:
     "<name>": {
        "value": ...,
        "unit": ...,
        "status": "...",
        "warning_threshold": ...,
        "critical_threshold": ...,
        "source": ...,
        "observation": ...
     }
  Os argumentos pcValue, pcUnit, pcWarn, pcCrit, pcSource, pcObs
  podem chegar como string vazia/desconhecida — nesse caso são
  serializados como null no JSON. Já pcValue é assumido como já
  formatado (chamadores devem usar fnJsonNum/fnJsonInt/fnJsonStr).
 -----------------------------------------------------------------*/
FUNCTION fnMetric RETURNS CHARACTER
    (INPUT pcName       AS CHARACTER,
     INPUT pcValue      AS CHARACTER,
     INPUT pcUnit       AS CHARACTER,
     INPUT pcStatus     AS CHARACTER,
     INPUT pcWarn       AS CHARACTER,
     INPUT pcCrit       AS CHARACTER,
     INPUT pcSource     AS CHARACTER,
     INPUT pcObs        AS CHARACTER) FORWARD.

/*------------------------------------------------------------------
  fnClassHigh: classifica uma métrica em que valores ALTOS são bons.
  Retorna "healthy" / "warning" / "critical" / "unknown".
  Exemplo: buffer hit ratio (>=95% saudável).
 -----------------------------------------------------------------*/
FUNCTION fnClassHigh RETURNS CHARACTER
    (INPUT pdVal AS DECIMAL,
     INPUT pdWarn AS DECIMAL,
     INPUT pdCrit AS DECIMAL) FORWARD.

/*------------------------------------------------------------------
  fnClassLow: classifica uma métrica em que valores BAIXOS são bons.
  Exemplo: physical reads/seg (<50/s saudável).
 -----------------------------------------------------------------*/
FUNCTION fnClassLow RETURNS CHARACTER
    (INPUT pdVal AS DECIMAL,
     INPUT pdWarn AS DECIMAL,
     INPUT pdCrit AS DECIMAL) FORWARD.

/*------------------------------------------------------------------
  fnExtractParam: extrai o valor numérico de um parâmetro de startup
  a partir da string DBPARAM(1), por exemplo "-B 50000 -L 8192 ...".
  Retorna ? quando o parâmetro não está presente ou não é numérico.
 -----------------------------------------------------------------*/
FUNCTION fnExtractParam RETURNS INT64
    (INPUT pcParams AS CHARACTER,
     INPUT pcKey    AS CHARACTER) FORWARD.

/*------------------------------------------------------------------
  fnParseCtime: converte data no formato ctime do C para DATETIME.
  Formato: "Sat Oct 28 20:24:16 2023" (dia_semana mês dia HH:MM:SS ano)
  Retorna ? se a string não puder ser parseada.
 -----------------------------------------------------------------*/
FUNCTION fnParseCtime RETURNS DATETIME
    (INPUT pcDate AS CHARACTER) FORWARD.

/* ====================================================================
   IMPLEMENTAÇÃO DAS FUNÇÕES
   ==================================================================== */

FUNCTION fnEscape RETURNS CHARACTER (INPUT pcVal AS CHARACTER):
    /* Escapa caracteres conforme RFC 8259 (subset comum).
       Usa CHR() para evitar ambiguidade com o escape de string ABL. */
    DEFINE VARIABLE cOut AS CHARACTER NO-UNDO.
    IF pcVal = ? THEN RETURN "".
    cOut = pcVal.
    /* Backslash (CHR 92) deve ser o PRIMEIRO a ser substituído */
    cOut = REPLACE(cOut, CHR(92), CHR(92) + CHR(92)).
    cOut = REPLACE(cOut, CHR(34), CHR(92) + CHR(34)).
    cOut = REPLACE(cOut, CHR(13), CHR(92) + "r").
    cOut = REPLACE(cOut, CHR(10), CHR(92) + "n").
    cOut = REPLACE(cOut, CHR(9),  CHR(92) + "t").
    cOut = REPLACE(cOut, CHR(8),  CHR(92) + "b").
    cOut = REPLACE(cOut, CHR(12), CHR(92) + "f").
    RETURN cOut.
END FUNCTION.

FUNCTION fnJsonStr RETURNS CHARACTER (INPUT pcVal AS CHARACTER):
    IF pcVal = ? OR pcVal = "" THEN RETURN "null".
    RETURN CHR(34) + fnEscape(pcVal) + CHR(34).
END FUNCTION.

FUNCTION fnJsonNum RETURNS CHARACTER (INPUT pdVal AS DECIMAL):
    DEFINE VARIABLE cR AS CHARACTER NO-UNDO.
    IF pdVal = ? THEN RETURN "null".
    /* TRIM(STRING(decimal)) usa o separador decimal do session locale.
       Forçamos ponto via REPLACE para JSON estritamente válido.
       JSON RFC 8259 exige zero à esquerda: 0.02, não .02.
       ABL pode retornar ".02" para valores entre -1 e 1. */
    cR = TRIM(STRING(pdVal)).
    cR = REPLACE(cR, ",", ".").
    /* Garante zero à esquerda para JSON válido */
    IF cR BEGINS "." THEN cR = "0" + cR.
    IF cR BEGINS "-." THEN cR = "-0" + SUBSTRING(cR, 2).
    RETURN cR.
END FUNCTION.

FUNCTION fnJsonInt RETURNS CHARACTER (INPUT piVal AS INT64):
    IF piVal = ? THEN RETURN "null".
    RETURN TRIM(STRING(piVal)).
END FUNCTION.

FUNCTION fnRound2 RETURNS DECIMAL (INPUT pdVal AS DECIMAL):
    IF pdVal = ? THEN RETURN ?.
    RETURN ROUND(pdVal, 2).
END FUNCTION.

FUNCTION fnDivSafe RETURNS DECIMAL (INPUT pdNum AS DECIMAL,
                                    INPUT pdDen AS DECIMAL):
    IF pdNum = ? OR pdDen = ? OR pdDen = 0 THEN RETURN 0.
    RETURN pdNum / pdDen.
END FUNCTION.

FUNCTION fnMetric RETURNS CHARACTER
    (INPUT pcName       AS CHARACTER,
     INPUT pcValue      AS CHARACTER,
     INPUT pcUnit       AS CHARACTER,
     INPUT pcStatus     AS CHARACTER,
     INPUT pcWarn       AS CHARACTER,
     INPUT pcCrit       AS CHARACTER,
     INPUT pcSource     AS CHARACTER,
     INPUT pcObs        AS CHARACTER):

    DEFINE VARIABLE cVal    AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cStatus AS CHARACTER NO-UNDO.

    /* value já vem pré-formatado pelo chamador (número, string ou null) */
    cVal    = IF pcValue = "" OR pcValue = ? THEN "null" ELSE pcValue.
    cStatus = IF pcStatus = "" OR pcStatus = ? THEN "unknown" ELSE pcStatus.

    /* Modo compacto (padrão): retorna apenas "nome": valor
       Modo debug: retorna objeto completo com metadados */
    IF NOT glDebug THEN
        RETURN gcQ + pcName + gcQ + ":" + cVal.

    RETURN gcQ + pcName + gcQ + ":" + gcLB
         + gcQ + "value"              + gcQ + ":" + cVal                + ","
         + gcQ + "unit"               + gcQ + ":" + fnJsonStr(pcUnit)   + ","
         + gcQ + "status"             + gcQ + ":" + gcQ + cStatus + gcQ + ","
         + gcQ + "warning_threshold"  + gcQ + ":" + fnJsonStr(pcWarn)   + ","
         + gcQ + "critical_threshold" + gcQ + ":" + fnJsonStr(pcCrit)   + ","
         + gcQ + "source"             + gcQ + ":" + fnJsonStr(pcSource) + ","
         + gcQ + "observation"        + gcQ + ":" + fnJsonStr(pcObs)
         + gcRB.
END FUNCTION.

FUNCTION fnClassHigh RETURNS CHARACTER
    (INPUT pdVal AS DECIMAL,
     INPUT pdWarn AS DECIMAL,
     INPUT pdCrit AS DECIMAL):
    IF pdVal = ? THEN RETURN "unknown".
    IF pdVal < pdCrit THEN RETURN "critical".
    IF pdVal < pdWarn THEN RETURN "warning".
    RETURN "healthy".
END FUNCTION.

FUNCTION fnClassLow RETURNS CHARACTER
    (INPUT pdVal AS DECIMAL,
     INPUT pdWarn AS DECIMAL,
     INPUT pdCrit AS DECIMAL):
    IF pdVal = ? THEN RETURN "unknown".
    IF pdVal > pdCrit THEN RETURN "critical".
    IF pdVal > pdWarn THEN RETURN "warning".
    RETURN "healthy".
END FUNCTION.

FUNCTION fnExtractParam RETURNS INT64
    (INPUT pcParams AS CHARACTER,
     INPUT pcKey    AS CHARACTER):

    DEFINE VARIABLE iPos    AS INTEGER   NO-UNDO.
    DEFINE VARIABLE cRest   AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cVal    AS CHARACTER NO-UNDO.
    DEFINE VARIABLE iRet    AS INT64     NO-UNDO INITIAL ?.
    DEFINE VARIABLE cNorm   AS CHARACTER NO-UNDO.

    IF pcParams = ? OR pcParams = "" THEN RETURN ?.

    /* DBPARAM pode retornar separado por vírgula ou espaço.
       Normalizamos vírgula para espaço antes de buscar. */
    cNorm = REPLACE(pcParams, ",", " ").

    /* Procura o token isolado: " -B " */
    iPos = INDEX(" " + cNorm + " ", " " + pcKey + " ").
    IF iPos = 0 THEN RETURN ?.

    /* Compensa o " " inicial inserido pelo INDEX */
    cRest = SUBSTRING(cNorm, iPos + LENGTH(pcKey)).
    cRest = TRIM(cRest).
    cVal  = ENTRY(1, cRest, " ").

    iRet = INT64(cVal) NO-ERROR.
    RETURN iRet.
END FUNCTION.

FUNCTION fnParseCtime RETURNS DATETIME (INPUT pcDate AS CHARACTER):
    /* Converte data formato ctime "Sat Oct 28 20:24:16 2023" para DATETIME.
       Se a string vier vazia, nula ou não-parseável, retorna ?. */
    DEFINE VARIABLE cNorm   AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cMonth  AS CHARACTER NO-UNDO.
    DEFINE VARIABLE iMonth  AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iDay    AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iYear   AS INTEGER   NO-UNDO.
    DEFINE VARIABLE cTime   AS CHARACTER NO-UNDO.
    DEFINE VARIABLE iHour   AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iMin    AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iSec    AS INTEGER   NO-UNDO.
    DEFINE VARIABLE dtRet   AS DATETIME  NO-UNDO INITIAL ?.

    IF pcDate = ? OR pcDate = "" OR pcDate = "?" THEN RETURN ?.

    /* Normaliza espaços duplos (dias < 10 podem ter "  8") */
    cNorm = REPLACE(TRIM(pcDate), "  ", " ").

    /* Espera 5 tokens: DayOfWeek Month Day Time Year */
    IF NUM-ENTRIES(cNorm, " ") < 5 THEN RETURN ?.

    cMonth = ENTRY(2, cNorm, " ").
    iDay   = INTEGER(ENTRY(3, cNorm, " ")) NO-ERROR.
    cTime  = ENTRY(4, cNorm, " ").
    iYear  = INTEGER(ENTRY(5, cNorm, " ")) NO-ERROR.

    IF iDay = ? OR iYear = ? THEN RETURN ?.

    /* Converte abreviação do mês para número */
    CASE cMonth:
        WHEN "Jan" THEN iMonth = 1.
        WHEN "Feb" THEN iMonth = 2.
        WHEN "Mar" THEN iMonth = 3.
        WHEN "Apr" THEN iMonth = 4.
        WHEN "May" THEN iMonth = 5.
        WHEN "Jun" THEN iMonth = 6.
        WHEN "Jul" THEN iMonth = 7.
        WHEN "Aug" THEN iMonth = 8.
        WHEN "Sep" THEN iMonth = 9.
        WHEN "Oct" THEN iMonth = 10.
        WHEN "Nov" THEN iMonth = 11.
        WHEN "Dec" THEN iMonth = 12.
        OTHERWISE RETURN ?.
    END CASE.

    /* Parseia HH:MM:SS */
    IF NUM-ENTRIES(cTime, ":") < 3 THEN RETURN ?.
    iHour = INTEGER(ENTRY(1, cTime, ":")) NO-ERROR.
    iMin  = INTEGER(ENTRY(2, cTime, ":")) NO-ERROR.
    iSec  = INTEGER(ENTRY(3, cTime, ":")) NO-ERROR.

    IF iHour = ? OR iMin = ? OR iSec = ? THEN RETURN ?.

    dtRet = DATETIME(iMonth, iDay, iYear, iHour, iMin, iSec) NO-ERROR.
    RETURN dtRet.
END FUNCTION.


/* ====================================================================
   PROCEDIMENTOS DE COLETA — UM POR CATEGORIA
   --------------------------------------------------------------------
   Cada procedure é totalmente isolada por DO ON ERROR UNDO, LEAVE.
   Em caso de falha de uma métrica específica, o valor é deixado
   nulo e a observação da métrica registra o motivo.
   ==================================================================== */

/* --------------------------------------------------------------------
   pAddError: registra uma entrada no array global "errors" do JSON
   final e atualiza os contadores de severidade.
   -------------------------------------------------------------------- */
PROCEDURE pAddError:
    DEFINE INPUT PARAMETER pcMetric   AS CHARACTER NO-UNDO.
    DEFINE INPUT PARAMETER pcMessage  AS CHARACTER NO-UNDO.
    DEFINE INPUT PARAMETER pcSource   AS CHARACTER NO-UNDO.
    DEFINE INPUT PARAMETER pcSeverity AS CHARACTER NO-UNDO.

    IF gcErrorsJson > "" THEN gcErrorsJson = gcErrorsJson + ",".

    gcErrorsJson = gcErrorsJson
        + gcLB + gcQ + "metric"   + gcQ + ":" + fnJsonStr(pcMetric)
        + "," + gcQ + "message"   + gcQ + ":" + fnJsonStr(pcMessage)
        + "," + gcQ + "source"    + gcQ + ":" + fnJsonStr(pcSource)
        + "," + gcQ + "severity"  + gcQ + ":" + fnJsonStr(pcSeverity)
        + gcRB.

    IF pcSeverity = "error"   THEN giErrorCount   = giErrorCount + 1.
    IF pcSeverity = "warning" THEN giWarningCount = giWarningCount + 1.
END PROCEDURE.


/* ====================================================================
   pCollectIdentification — Identificação do banco
   --------------------------------------------------------------------
   VSTs / fontes:
     LDBNAME(1)        — nome lógico do banco conectado (1ª conexão)
     PDBNAME(1)        — nome físico do banco conectado
     PROVERSION        — versão do produto Progress
     OS-GETENV(...)    — hostname do servidor
     _MyConnection     — informações do processo conectado (PID)
     _DbStatus         — estado e StartTime do banco para uptime
     _Connect          — número de conexões ativas
   ==================================================================== */
PROCEDURE pCollectIdentification:

    DEFINE VARIABLE iCount AS INTEGER  NO-UNDO INITIAL 0.
    DEFINE VARIABLE dtTmp  AS DATETIME NO-UNDO.

    /* ---- Nome lógico (descoberto em runtime, não hardcoded) ---- */
    DO ON ERROR UNDO, LEAVE:
        gcLogicalName = LDBNAME(1).
        IF gcLogicalName = ? THEN gcLogicalName = "".
    END.

    /* ---- Nome físico (caminho do .db conectado) ---- */
    DO ON ERROR UNDO, LEAVE:
        gcPhysicalName = PDBNAME(1).
        IF gcPhysicalName = ? THEN gcPhysicalName = "".
        gcPhysicalPath = gcPhysicalName.
    END.

    /* ---- Versão do Progress (PROVERSION) ---- */
    DO ON ERROR UNDO, LEAVE:
        gcDbVersion = PROVERSION.
    END.

    /* ---- Hostname: obtido via variáveis de ambiente.
            INPUT FROM / INPUT THROUGH conflitam com BLOCK-LEVEL ON
            ERROR UNDO, THROW e não compilam neste contexto.
            Fontes: COMPUTERNAME (Windows), HOSTNAME (Linux). ---- */
    DO ON ERROR UNDO, LEAVE:
        gcHost = OS-GETENV("COMPUTERNAME").
        IF gcHost = ? OR gcHost = "" THEN gcHost = OS-GETENV("HOSTNAME").
        IF gcHost = ? THEN gcHost = "".
    END.

    /* ---- PID do processo: deixado nulo (0) —
            _MyConnection não está disponível ou é ambígua em algumas
            instalações OE 12.2. Pode ser obtido externamente via
            comando shell que invoca o mpro/_progres. ---- */
    giPid = 0.

    /* ---- Estado do banco e tempo de início (uptime) ---- */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _DbStatus NO-LOCK NO-ERROR.
        IF AVAILABLE _DbStatus THEN DO:
            gcDbStatus = "online".

            /* _DbStatus-StartTime: pode ser CHARACTER formatado, INTEGER
               ou já um datetime — usamos NO-ERROR em todas as conversões */
            dtTmp = DATETIME(STRING(_DbStatus-StartTime)) NO-ERROR.
            IF dtTmp NE ? THEN gdtStartTime = dtTmp.
        END.
        ELSE
            RUN pAddError("identification.db_status",
                          "VST _DbStatus indisponível",
                          "_DbStatus", "warning").
    END.

    /* Calcula uptime em segundos — usa _Summary-UpTime que é a fonte
       mais confiável (INTEGER, direto em segundos). Fallback para
       INTERVAL(NOW, _DbStatus-StartTime) se indisponível. */
    gdtNow = NOW.
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActSummary NO-LOCK NO-ERROR.
        IF AVAILABLE _ActSummary AND _Summary-UpTime > 0 THEN
            gdUptimeSec = DECIMAL(_Summary-UpTime).
    END.
    IF gdUptimeSec <= 1 AND gdtStartTime NE ? THEN
        gdUptimeSec = INTERVAL(gdtNow, gdtStartTime, "seconds").
    IF gdUptimeSec = ? OR gdUptimeSec <= 0 THEN gdUptimeSec = 1.

    /* ---- Conexões ativas ---- */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _Connect NO-LOCK
            WHERE _Connect._Connect-Name <> ""
              AND _Connect._Connect-Name <> ?:
            iCount = iCount + 1.
        END.
        giActConnects = iCount.
    END.
END PROCEDURE.


/* ====================================================================
   pCollectIO — I/O e Armazenamento
   --------------------------------------------------------------------
   VSTs:
     _ActBuffer  — leituras lógicas/físicas, checkpoints, flushed
     _ActSummary — db accesses, db reads/writes, bi/ai reads/writes,
                   commits, undos, transações
     _AreaStatus — high water mark, blocos livres, blocos vazios
     _Area       — block size por área (utilizado para info)
     _MstrBlk    — db block size, BI block size, AI block size
     _ActBILog   — atividade do BI log
     _ActAILog   — atividade do AI log

   Observação: o "disk_free_percent" não está acessível diretamente
   por VST do Progress; é marcado como null com observação.
   Métricas "por segundo" são calculadas sobre o uptime do banco
   (média desde o startup) — para taxas instantâneas seria preciso
   amostragem delta entre execuções.
   ==================================================================== */
PROCEDURE pCollectIO:

    DEFINE VARIABLE dLogicRds     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dOSRds        AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dDbReads      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dDbWrites     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dCheckpoints  AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dHitRatio     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dReadsPerSec  AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dWritesPerSec AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dCkptPerMin   AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBiUsage      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dAiGrowthHr   AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBiBytes      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dAiBytes      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE iDbBlkSize    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiBlkSize    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iAiBlkSize    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iHiWater      AS INT64   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iFreeBlks     AS INT64   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iEmptyBlks    AS INT64   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iAreaCount    AS INTEGER NO-UNDO INITIAL 0.

    /* _Logging: tamanhos de BI e AI */
    DEFINE VARIABLE iBiLogSize    AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiBytesFree  AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiExtents    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiClusterHWM AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiCurrClust  AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iAiLogSize    AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iAiExtents    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iAiCurrExt    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBiSizeGB     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dAiSizeGB     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBiUsedPct    AS DECIMAL NO-UNDO INITIAL ?.

    /* Tamanho do arquivo .lg (log do banco) via FILE-INFO */
    DEFINE VARIABLE iLogFileSize  AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE dLogFileMB    AS DECIMAL NO-UNDO INITIAL ?.

    /* ============== _ActBuffer: leituras e checkpoints ============== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActBuffer NO-LOCK NO-ERROR.
        IF AVAILABLE _ActBuffer THEN DO:
            ASSIGN
                dLogicRds    = DECIMAL(_Buffer-LogicRds)
                dOSRds       = DECIMAL(_Buffer-OSRds).
        END.
        ELSE RUN pAddError("io.buffer",
                           "VST _ActBuffer indisponível",
                           "_ActBuffer", "warning").
    END.

    /* ============== _ActSummary: writes, contadores gerais e checkpoints ==
       Observação: checkpoints vêm de _ActSummary (_Summary-Chkpts) porque
       o campo _Buffer-Checkpoints NÃO existe no schema 12.2. ============ */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActSummary NO-LOCK NO-ERROR.
        IF AVAILABLE _ActSummary THEN DO:
            ASSIGN
                dDbReads     = DECIMAL(_Summary-DbReads)
                dDbWrites    = DECIMAL(_Summary-DbWrites)
                dCheckpoints = DECIMAL(_Summary-Chkpts) NO-ERROR.
        END.
        ELSE RUN pAddError("io.summary",
                           "VST _ActSummary indisponível",
                           "_ActSummary", "warning").
    END.

    /* ============== _MstrBlk: tamanhos de bloco BI/AI ===============
       Observação: o block size do banco em si depende da área (Type II
       pode variar). Coletamos via _Area-blocksize logo abaixo. */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _MstrBlk NO-LOCK NO-ERROR.
        IF AVAILABLE _MstrBlk THEN DO:
            iBiBlkSize = INTEGER(_MstrBlk-biblksize) NO-ERROR.
            iAiBlkSize = INTEGER(_MstrBlk-aiblksize) NO-ERROR.
        END.
    END.

    /* ============== _AreaStatus: HWM e free blocks ====================
       Observação: _AreaStatus-Emptynum NÃO existe no schema OE 12.2.
       Empty blocks ficará como null no JSON.
       Proteção: INT64(?) retorna ? — se qualquer área devolver ?,
       a soma inteira vira ?. Usamos variável temp com NO-ERROR para
       ignorar áreas com valor desconhecido. ========================== */
    DO ON ERROR UNDO, LEAVE:
        DEFINE VARIABLE iTmpHw AS INT64 NO-UNDO.
        DEFINE VARIABLE iTmpFr AS INT64 NO-UNDO.
        FOR EACH _AreaStatus NO-LOCK:
            ASSIGN iTmpHw = INT64(_AreaStatus-Hiwater) NO-ERROR.
            ASSIGN iTmpFr = INT64(_AreaStatus-Freenum) NO-ERROR.
            IF iTmpHw <> ? THEN iHiWater  = iHiWater  + iTmpHw.
            IF iTmpFr <> ? THEN iFreeBlks = iFreeBlks + iTmpFr.
            iAreaCount = iAreaCount + 1.
        END.
    END.

    /* ============== _Area: tamanho de bloco mais comum ============== */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _Area NO-LOCK WHERE _Area-number > 6:  /* ignora schema/control */
            IF iDbBlkSize = ? OR iDbBlkSize = 0 THEN
                iDbBlkSize = INTEGER(_Area-blocksize) NO-ERROR.
        END.
    END.

    /* ============== _ActBILog: atividade do BI (nomes validados) ====== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActBILog NO-LOCK NO-ERROR.
        IF AVAILABLE _ActBILog THEN
            dBiBytes = DECIMAL(_BiLog-BytesWrtn) NO-ERROR.
    END.

    /* ============== _ActAILog: crescimento do AI (nomes validados) == */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActAILog NO-LOCK NO-ERROR.
        IF AVAILABLE _ActAILog THEN DO:
            dAiBytes = DECIMAL(_AiLog-BytesWritn) NO-ERROR.
            IF dAiBytes <> ? AND gdUptimeSec > 0 THEN
                dAiGrowthHr = ROUND(dAiBytes / (gdUptimeSec / 3600), 2).
        END.
    END.

    /* ============== _Logging: tamanho real de BI e AI ==================
       _Logging é a VST que expõe os tamanhos reais dos logs BI/AI.
       _Logging-BiLogSize e _Logging-AiLogSize retornam o tamanho total
       em KB. Convertemos para GB dividindo por 1048576 (1024*1024).
       _Logging-BiBytesFree retorna bytes livres no BI — usado para
       calcular a % de utilização do BI log. ========================= */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _Logging NO-LOCK NO-ERROR.
        IF AVAILABLE _Logging THEN DO:
            iBiLogSize    = INT64(_Logging-BiLogSize)    NO-ERROR.
            iBiBytesFree  = INT64(_Logging-BiBytesFree)  NO-ERROR.
            iBiExtents    = INTEGER(_Logging-BiExtents)   NO-ERROR.
            iBiClusterHWM = INT64(_Logging-BiClusterHWM) NO-ERROR.
            iBiCurrClust  = INT64(_Logging-CurrBiCluster) NO-ERROR.
            iAiLogSize    = INT64(_Logging-AiLogSize)    NO-ERROR.
            iAiExtents    = INTEGER(_Logging-AiExtents)   NO-ERROR.
            iAiCurrExt    = INTEGER(_Logging-AiCurrExt)   NO-ERROR.

            /* Converte KB para GB (1 GB = 1024 * 1024 KB) */
            IF iBiLogSize <> ? THEN
                dBiSizeGB = ROUND(iBiLogSize / 1048576, 4).
            IF iAiLogSize <> ? THEN
                dAiSizeGB = ROUND(iAiLogSize / 1048576, 4).

            /* % de utilização do BI = (total - livre) / total * 100
               BiLogSize está em KB, BiBytesFree em bytes.
               Convertemos BiBytesFree para KB antes de calcular. */
            IF iBiLogSize <> ? AND iBiLogSize > 0 AND iBiBytesFree <> ? THEN
                dBiUsedPct = ROUND(
                    (iBiLogSize - (iBiBytesFree / 1024)) / iBiLogSize * 100, 2).
        END.
        ELSE RUN pAddError("io.logging",
                           "VST _Logging indisponível",
                           "_Logging", "warning").
    END.

    /* ============== Tamanho do arquivo .lg (log do banco) =============
       Usa FILE-INFO para obter o tamanho em bytes do arquivo de log.
       O caminho é derivado de PDBNAME(1) + ".lg". =================== */
    DO ON ERROR UNDO, LEAVE:
        FILE-INFO:FILE-NAME = PDBNAME(1) + ".lg".
        IF FILE-INFO:FULL-PATHNAME <> ? THEN DO:
            iLogFileSize = INT64(FILE-INFO:FILE-SIZE) NO-ERROR.
            IF iLogFileSize <> ? THEN
                dLogFileMB = ROUND(iLogFileSize / 1048576, 2).
        END.
    END.

    /* ============== Cálculos derivados ============================== */

    /* Buffer hit ratio = (logical - physical) / logical * 100 */
    IF dLogicRds <> ? AND dLogicRds > 0 THEN
        dHitRatio = ROUND((dLogicRds - dOSRds) / dLogicRds * 100, 2).

    /* Reads físicos por segundo = OSRds / uptime */
    IF dOSRds <> ? THEN
        dReadsPerSec = ROUND(dOSRds / gdUptimeSec, 2).

    /* Writes físicos por segundo = DbWrites / uptime */
    IF dDbWrites <> ? THEN
        dWritesPerSec = ROUND(dDbWrites / gdUptimeSec, 2).

    /* Checkpoints por minuto = checkpoints / (uptime/60) */
    IF dCheckpoints <> ? AND gdUptimeSec > 0 THEN
        dCkptPerMin = ROUND(dCheckpoints / (gdUptimeSec / 60), 2).

    /* ============== Montagem da seção JSON ========================== */

    gcSecIO = ""
        + fnMetric("buffer_hit_ratio",
                   fnJsonNum(dHitRatio), "percent",
                   fnClassHigh(dHitRatio, 95, 90),
                   "90-94", "<90",
                   "_ActBuffer (_Buffer-LogicRds, _Buffer-OSRds)",
                   "Calculado: (LogicRds - OSRds) / LogicRds * 100. Média acumulada desde startup do banco.")

        + "," + fnMetric("physical_reads_per_sec",
                   fnJsonNum(dReadsPerSec), "reads/sec",
                   fnClassLow(dReadsPerSec, 50, 200),
                   "50-200", ">200",
                   "_ActBuffer / uptime",
                   "Média desde startup; para taxa instantânea use amostragem delta.")

        + "," + fnMetric("physical_writes_per_sec",
                   fnJsonNum(dWritesPerSec), "writes/sec",
                   fnClassLow(dWritesPerSec, 30, 100),
                   "30-100", ">100",
                   "_ActSummary._Summary-DbWrites / uptime",
                   "Média desde startup; para taxa instantânea use amostragem delta.")

        + "," + fnMetric("checkpoint_frequency_per_min",
                   fnJsonNum(dCkptPerMin), "checkpoints/min",
                   fnClassLow(dCkptPerMin, 1, 5),
                   "1-5", ">5",
                   "_ActSummary._Summary-Chkpts / (uptime/60)",
                   "Frequência média de checkpoints desde startup.")

        + "," + fnMetric("bi_log_usage_percent",
                   fnJsonNum(dBiUsedPct), "percent",
                   fnClassLow(dBiUsedPct, 50, 80),
                   "50-80", ">80",
                   "_Logging (BiLogSize - BiBytesFree) / BiLogSize * 100",
                   "Percentual de utilização do BI log.")

        + "," + fnMetric("ai_log_growth_per_hour",
                   fnJsonNum(dAiGrowthHr), "bytes/hour",
                   "unknown", "", "",
                   "_ActAILog._AiLog-BytesWriten / (uptime/3600)",
                   "Crescimento médio do AI log estimado pelo uptime; pressupõe AI ativo.")

        + "," + fnMetric("disk_free_percent",
                   "null", "percent",
                   "unknown", "20-30", "<20",
                   "OS / df",
                   "Espaço livre em disco não é exposto pelas VSTs do Progress; coletar via shell externo.")

        + "," + fnMetric("db_block_size",
                   fnJsonInt(iDbBlkSize), "bytes",
                   "healthy", "", "",
                   "_Area._Area-blocksize",
                   "Tamanho de bloco da primeira área de dados (>area 6).")

        + "," + fnMetric("bi_block_size",
                   fnJsonInt(iBiBlkSize), "bytes",
                   "healthy", "", "",
                   "_MstrBlk._MstrBlk-biblksize", "")

        + "," + fnMetric("ai_block_size",
                   fnJsonInt(iAiBlkSize), "bytes",
                   "healthy", "", "",
                   "_MstrBlk._MstrBlk-aiblksize", "")

        + "," + fnMetric("hi_water_total_blocks",
                   fnJsonInt(iHiWater), "blocks",
                   "healthy", "", "",
                   "SUM(_AreaStatus._AreaStatus-Hiwater)",
                   "Soma do high water mark de todas as áreas.")

        + "," + fnMetric("free_blocks",
                   fnJsonInt(iFreeBlks), "blocks",
                   "healthy", "", "",
                   "SUM(_AreaStatus._AreaStatus-Freenum)", "")

        + "," + fnMetric("empty_blocks",
                   "null", "blocks",
                   "unknown", "", "",
                   "_AreaStatus",
                   "Campo _AreaStatus-Emptynum não existe no schema OE 12.2.")

        + "," + fnMetric("logical_reads_total",
                   fnJsonNum(dLogicRds), "reads",
                   "healthy", "", "",
                   "_ActBuffer._Buffer-LogicRds",
                   "Total acumulado desde startup.")

        + "," + fnMetric("physical_reads_total",
                   fnJsonNum(dOSRds), "reads",
                   "healthy", "", "",
                   "_ActBuffer._Buffer-OSRds",
                   "Total acumulado desde startup.")

        + "," + fnMetric("db_writes_total",
                   fnJsonNum(dDbWrites), "writes",
                   "healthy", "", "",
                   "_ActSummary._Summary-DbWrites",
                   "Total acumulado desde startup.")

        + "," + fnMetric("areas_count",
                   fnJsonInt(iAreaCount), "areas",
                   "healthy", "", "",
                   "COUNT(_AreaStatus)", "")

        /* ============== Métricas de BI Log (via _Logging) ============ */
        + "," + fnMetric("bi_log_size_gb",
                   fnJsonNum(dBiSizeGB), "GB",
                   "healthy", "", "",
                   "_Logging._Logging-BiLogSize / 1048576",
                   "Tamanho total do BI log em GB.")

        + "," + fnMetric("bi_log_size_kb",
                   fnJsonInt(iBiLogSize), "KB",
                   "healthy", "", "",
                   "_Logging._Logging-BiLogSize",
                   "Tamanho total do BI log em KB (valor bruto).")

        + "," + fnMetric("bi_bytes_free",
                   fnJsonInt(iBiBytesFree), "bytes",
                   "healthy", "", "",
                   "_Logging._Logging-BiBytesFree",
                   "Bytes livres no BI log.")

        + "," + fnMetric("bi_extents",
                   fnJsonInt(iBiExtents), "extents",
                   "healthy", "", "",
                   "_Logging._Logging-BiExtents",
                   "Número de extents do BI.")

        + "," + fnMetric("bi_cluster_hwm",
                   fnJsonInt(iBiClusterHWM), "clusters",
                   "healthy", "", "",
                   "_Logging._Logging-BiClusterHWM",
                   "High water mark de clusters BI.")

        + "," + fnMetric("bi_current_cluster",
                   fnJsonInt(iBiCurrClust), "cluster",
                   "healthy", "", "",
                   "_Logging._Logging-CurrBiCluster",
                   "Cluster BI atual em uso.")

        /* ============== Métricas de AI Log (via _Logging) ============ */
        + "," + fnMetric("ai_log_size_gb",
                   fnJsonNum(dAiSizeGB), "GB",
                   "healthy", "", "",
                   "_Logging._Logging-AiLogSize / 1048576",
                   "Tamanho total do AI log em GB.")

        + "," + fnMetric("ai_log_size_kb",
                   fnJsonInt(iAiLogSize), "KB",
                   "healthy", "", "",
                   "_Logging._Logging-AiLogSize",
                   "Tamanho total do AI log em KB (valor bruto).")

        + "," + fnMetric("ai_extents",
                   fnJsonInt(iAiExtents), "extents",
                   "healthy", "", "",
                   "_Logging._Logging-AiExtents",
                   "Número de extents do AI.")

        + "," + fnMetric("ai_current_extent",
                   fnJsonInt(iAiCurrExt), "extent",
                   "healthy", "", "",
                   "_Logging._Logging-AiCurrExt",
                   "Extent AI atual em uso.")

        /* ============== Log file (.lg) =============================== */
        + "," + fnMetric("log_file_size_mb",
                   fnJsonNum(dLogFileMB), "MB",
                   "healthy", "", "",
                   "FILE-INFO:FILE-SIZE de PDBNAME(1) + .lg",
                   "Tamanho do arquivo de log do banco em MB.")

        + "," + fnMetric("log_file_size_bytes",
                   fnJsonInt(iLogFileSize), "bytes",
                   "healthy", "", "",
                   "FILE-INFO:FILE-SIZE",
                   "Tamanho bruto em bytes do arquivo .lg.").
END PROCEDURE.


/* ====================================================================
   pCollectMemory — Memória e Buffers
   --------------------------------------------------------------------
   VSTs:
     _ActBuffer  — LRU skips, marked, flushed
     _Resrc      — recursos: "Record Locks", "Buffers" — atual vs HWM
     _Latch      — estatísticas de latches (hash chain proxy)

   Observações:
     - "shared_memory_used_percent" não é exposto via VST.
     - "hash_chain_avg_length" não é diretamente derivável; usamos
       null com observação.
   ==================================================================== */
PROCEDURE pCollectMemory:

    DEFINE VARIABLE dLruSkips      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dLruPerSec     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBufPoolPct    AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dLockTablePct  AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE iLockCur       AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iLockHwm       AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBufCur        AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBufHwm        AS INT64   NO-UNDO INITIAL ?.

    /* ============== _ActBuffer: LRU skips ====================== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActBuffer NO-LOCK NO-ERROR.
        IF AVAILABLE _ActBuffer THEN DO:
            dLruSkips  = DECIMAL(_Buffer-LRUSkips) NO-ERROR.
            IF dLruSkips <> ? THEN
                dLruPerSec = ROUND(dLruSkips / gdUptimeSec, 2).
        END.
    END.

    /* ============== _Resrc: Record Locks (lock table %) ==========
       Nomes dos registros _Resrc podem variar entre ambientes.
       Usamos BEGINS para busca parcial caso o nome exato difira.
       Também coletamos TODOS os _Resrc-Name para diagnóstico. ==== */
    DO ON ERROR UNDO, LEAVE:
        DEFINE VARIABLE cResrcNames AS CHARACTER NO-UNDO INITIAL "".
        FOR EACH _Resrc NO-LOCK:
            IF cResrcNames > "" THEN cResrcNames = cResrcNames + ", ".
            cResrcNames = cResrcNames + _Resrc-Name.

            IF _Resrc-Name = "Record Lock" THEN
                iLockCur = INT64(_Resrc-Lock) NO-ERROR.

            IF _Resrc-Name = "DB Buf Avail" THEN
                iBufCur = INT64(_Resrc-Lock) NO-ERROR.
        END.

        /* % uso lock table = atual / -L * 100  (se -L conhecido) */
        IF giParamL <> ? AND giParamL > 0 AND iLockCur <> ? THEN
            dLockTablePct = ROUND(iLockCur / giParamL * 100, 2).

        /* % uso buffer pool = atual / -B * 100  (se -B conhecido) */
        IF giParamB <> ? AND giParamB > 0 AND iBufCur <> ? THEN
            dBufPoolPct = ROUND(iBufCur / giParamB * 100, 2).
    END.

    /* ============== Montagem da seção JSON ===================== */

    gcSecMem = ""
        + fnMetric("buffer_pool_used_percent",
                   fnJsonNum(dBufPoolPct), "percent",
                   fnClassLow(dBufPoolPct, 80, 95),
                   "80-94", ">=95",
                   "_Resrc[Buffers] vs -B",
                   "Calculado a partir de _Resrc-Lock para 'Buffers' dividido pelo parâmetro -B obtido em DBPARAM.")

        + "," + fnMetric("lru_scans_per_sec",
                   fnJsonNum(dLruPerSec), "scans/sec",
                   fnClassLow(dLruPerSec, 100, 1000),
                   "100-1000", ">1000",
                   "_ActBuffer._Buffer-LRUSkips / uptime",
                   "Média desde startup.")

        + "," + fnMetric("lock_table_used_percent",
                   fnJsonNum(dLockTablePct), "percent",
                   fnClassLow(dLockTablePct, 70, 90),
                   "70-89", ">=90",
                   "_Resrc[Record Locks] vs -L",
                   "Locks atuais sobre a capacidade configurada -L.")

        + "," + fnMetric("lock_table_current",
                   fnJsonInt(iLockCur), "locks",
                   "healthy", "", "",
                   "_Resrc._Resrc-Lock", "")

        + "," + fnMetric("lock_table_hwm",
                   "null", "locks",
                   "unknown", "", "",
                   "_Resrc",
                   "Campo _Resrc-Hwm não existe neste schema OE 12.2.")

        + "," + fnMetric("buffer_pool_current",
                   fnJsonInt(iBufCur), "buffers",
                   "healthy", "", "",
                   "_Resrc[Buffers]._Resrc-Lock", "")

        + "," + fnMetric("buffer_pool_hwm",
                   "null", "buffers",
                   "unknown", "", "",
                   "_Resrc",
                   "Campo _Resrc-Hwm não existe neste schema OE 12.2.")

        + "," + fnMetric("shared_memory_used_percent",
                   "null", "percent",
                   "unknown", "70-90", ">90",
                   "OS",
                   "Não exposto via VST do Progress; coletar via comandos do SO (ipcs, /proc/meminfo).")

        + "," + fnMetric("hash_chain_avg_length",
                   "null", "entries",
                   "unknown", "", "",
                   "_Latch / cálculo interno",
                   "Não derivável diretamente das VSTs públicas em 12.2.")

        .
END PROCEDURE.


/* ====================================================================
   pCollectTransactions — Transações
   --------------------------------------------------------------------
   VSTs:
     _ActSummary — commits, undos, transactions totais
     _Trans      — transações ativas (estado, duração, usuário)
     _MstrBlk    — _MstrBlk-rlclsize (BI cluster size)
   ==================================================================== */
PROCEDURE pCollectTransactions:

    DEFINE VARIABLE dCommits      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dUndos        AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dTrans        AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dTps          AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dRollbackPct  AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE iActiveTrans  AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iLongTrans    AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iLongestTrans AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE dDurSum       AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE iDurCount     AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE dAvgDuration  AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiClusterKB  AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iTransDur     AS INTEGER NO-UNDO.

    /* ============== _ActSummary: commits/undos/trans totais =====
       Nomes de campos validados contra o schema real:
         _Summary-Commits (com 's'), _Summary-Undos (com 's'),
         _Summary-TransComm (transações committed). =============== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActSummary NO-LOCK NO-ERROR.
        IF AVAILABLE _ActSummary THEN DO:
            dCommits = DECIMAL(_Summary-Commits)   NO-ERROR.
            dUndos   = DECIMAL(_Summary-Undos)     NO-ERROR.
            dTrans   = DECIMAL(_Summary-TransComm) NO-ERROR.

            IF dTrans <> ? AND gdUptimeSec > 0 THEN
                dTps = ROUND(dTrans / gdUptimeSec, 2).

            /* Taxa de rollback = undos / (commits + undos) * 100 */
            IF dCommits <> ? AND dUndos <> ? AND (dCommits + dUndos) > 0 THEN
                dRollbackPct = ROUND(dUndos / (dCommits + dUndos) * 100, 2).
        END.
    END.

    /* ============== _Trans: transações ativas e duração ========= */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _Trans NO-LOCK
            WHERE _Trans._Trans-State <> ""
              AND _Trans._Trans-State <> ?:

            iTransDur = INTEGER(_Trans._Trans-Duration) NO-ERROR.
            IF iTransDur = ? THEN iTransDur = 0.

            iActiveTrans = iActiveTrans + 1.

            IF iTransDur > 60 THEN iLongTrans = iLongTrans + 1.

            IF iTransDur > iLongestTrans THEN iLongestTrans = iTransDur.

            dDurSum   = dDurSum   + iTransDur.
            iDurCount = iDurCount + 1.
        END.

        IF iDurCount > 0 THEN
            dAvgDuration = ROUND(dDurSum / iDurCount, 2).
    END.

    /* ============== _MstrBlk: BI cluster size ================== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _MstrBlk NO-LOCK NO-ERROR.
        IF AVAILABLE _MstrBlk THEN
            iBiClusterKB = INTEGER(_MstrBlk-rlclsize) NO-ERROR.
    END.

    /* ============== Montagem da seção JSON ===================== */

    gcSecTrx = ""
        + fnMetric("tps",
                   fnJsonNum(dTps), "trans/sec",
                   "healthy", "", "",
                   "_ActSummary._Summary-TransComm / uptime",
                   "Média desde startup; pico real exige amostragem delta.")

        + "," + fnMetric("active_transactions",
                   fnJsonInt(iActiveTrans), "transactions",
                   "healthy", "", "",
                   "COUNT(_Trans WHERE _Trans-State <> '')", "")

        + "," + fnMetric("long_transactions_over_60s",
                   fnJsonInt(iLongTrans), "transactions",
                   IF iLongTrans = 0 THEN "healthy"
                   ELSE IF iLongTrans < 3 THEN "warning"
                   ELSE "critical",
                   "1-2", ">=3",
                   "_Trans._Trans-Duration > 60", "")

        + "," + fnMetric("longest_transaction_age_sec",
                   fnJsonInt(iLongestTrans), "seconds",
                   "healthy", "", "",
                   "MAX(_Trans._Trans-Duration)", "")

        + "," + fnMetric("rollback_rate_percent",
                   fnJsonNum(dRollbackPct), "percent",
                   fnClassLow(dRollbackPct, 1, 5),
                   "1-5", ">5",
                   "_ActSummary._Summary-Undo / (Commit + Undo)",
                   "Razão entre undos e total de operações de transação.")

        + "," + fnMetric("bi_cluster_avg_size_kb",
                   fnJsonInt(iBiClusterKB), "KB",
                   "healthy", "", "",
                   "_MstrBlk._MstrBlk-rlclsize",
                   "Tamanho de cluster do BI conforme estrutura.")

        + "," + fnMetric("avg_transaction_duration_sec",
                   fnJsonNum(dAvgDuration), "seconds",
                   "healthy", "", "",
                   "AVG(_Trans._Trans-Duration)", "")

        + "," + fnMetric("commits_total",
                   fnJsonNum(dCommits), "commits",
                   "healthy", "", "",
                   "_ActSummary._Summary-Commits",
                   "Total acumulado desde startup.")

        + "," + fnMetric("undos_total",
                   fnJsonNum(dUndos), "undos",
                   "healthy", "", "",
                   "_ActSummary._Summary-Undos",
                   "Total acumulado desde startup.")

        + "," + fnMetric("transactions_total",
                   fnJsonNum(dTrans), "transactions",
                   "healthy", "", "",
                   "_ActSummary._Summary-TransComm",
                   "Total acumulado desde startup.").
END PROCEDURE.


/* ====================================================================
   pCollectLocks — Bloqueios
   --------------------------------------------------------------------
   VSTs:
     _ActLock — atividade de locks (waits, requests)
     _Resrc   — record locks atuais (entrada "Record Locks")
     _Lock    — tabela de locks (apenas para contagem amostral)

   Observações:
     - lock_timeouts_per_hour e deadlocks_per_hour não são expostos
       diretamente; ficam null com observação.
     - avg_lock_wait_ms requer histórico ou amostragem delta.
   ==================================================================== */
PROCEDURE pCollectLocks:

    DEFINE VARIABLE dLockWaits      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dLockWaitsPerSec AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE iActiveLocks    AS INT64   NO-UNDO INITIAL ?.

    /* ============== _ActLock: lock waits ========================
       Não existe campo único _Lock-Wait. Soma dos waits reais:
         _Lock-ExclWait  (exclusive waits)
         _Lock-ShrWait   (share waits)
         _Lock-UpgWait   (upgrade waits)
         _Lock-RecGetWait (record-get waits)
       Todos validados contra o schema OE 12.2. ================== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _ActLock NO-LOCK NO-ERROR.
        IF AVAILABLE _ActLock THEN DO:
            dLockWaits = DECIMAL(_Lock-ExclWait)   NO-ERROR.
            dLockWaits = dLockWaits
                       + DECIMAL(_Lock-ShrWait)    NO-ERROR.
            dLockWaits = dLockWaits
                       + DECIMAL(_Lock-UpgWait)    NO-ERROR.
            dLockWaits = dLockWaits
                       + DECIMAL(_Lock-RecGetWait) NO-ERROR.
            IF dLockWaits <> ? THEN
                dLockWaitsPerSec = ROUND(dLockWaits / gdUptimeSec, 2).
        END.
    END.

    /* ============== _Resrc: record locks atuais ===============
       Nome real no OE 12.x: "Record Lock" (sem 's') ========= */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _Resrc
            WHERE _Resrc-Name = "Record Lock"
            NO-LOCK NO-ERROR.
        IF AVAILABLE _Resrc THEN
            iActiveLocks = INT64(_Resrc-Lock) NO-ERROR.
    END.

    /* ============== Montagem da seção JSON =================== */

    gcSecLck = ""
        + fnMetric("lock_waits_per_sec",
                   fnJsonNum(dLockWaitsPerSec), "waits/sec",
                   fnClassLow(dLockWaitsPerSec, 1, 10),
                   "1-10", ">10",
                   "_ActLock (ExclWait+ShrWait+UpgWait+RecGetWait) / uptime",
                   "Média desde startup.")

        + "," + fnMetric("lock_timeouts_per_hour",
                   "null", "events/hour",
                   "unknown", ">0", ">5",
                   "log de banco / OEM",
                   "Não exposto diretamente via VST; depende de parsing do .lg.")

        + "," + fnMetric("deadlocks_per_hour",
                   "null", "events/hour",
                   "unknown", ">0", ">1",
                   "log de banco / OEM",
                   "Não exposto diretamente via VST; depende de parsing do .lg.")

        + "," + fnMetric("active_record_locks",
                   fnJsonInt(iActiveLocks), "locks",
                   "healthy", "", "",
                   "_Resrc[Record Locks]._Resrc-Lock", "")

        + "," + fnMetric("avg_lock_wait_ms",
                   "null", "milliseconds",
                   "unknown", "100-500", ">500",
                   "histórico / amostragem delta",
                   "Não derivável diretamente das VSTs em uma única amostra.")

        + "," + fnMetric("lock_waits_total",
                   fnJsonNum(dLockWaits), "waits",
                   "healthy", "", "",
                   "_ActLock (soma dos waits)",
                   "Total acumulado desde startup.").
END PROCEDURE.


/* ====================================================================
   pCollectConnections — Conectividade e Disponibilidade
   --------------------------------------------------------------------
   VSTs:
     _Connect — sessões conectadas
     _DbStatus — informações gerais
   ==================================================================== */
PROCEDURE pCollectConnections:

    DEFINE VARIABLE iActive       AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iSelfConn     AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iRemoteConn   AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iBatchConn    AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iIdleOver30   AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE dActVsMaxPct  AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE cConnType     AS CHARACTER NO-UNDO.

    /* Contadores de processos de serviço do banco */
    DEFINE VARIABLE iBIW          AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iAIW          AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iWDOG         AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iAPW          AS INTEGER NO-UNDO INITIAL 0.

    /* ============== _Connect: sessões ativas e processos de serviço ==
       Além de contar conexões por tipo (SELF, BATCH, remote), detectamos
       processos de serviço: BIW (BI Writer), AIW (AI Writer),
       WDOG (Watchdog), APW (Async Page Writer). ===================== */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _Connect NO-LOCK
            WHERE _Connect._Connect-Name <> ""
              AND _Connect._Connect-Name <> ?:

            iActive = iActive + 1.

            cConnType = STRING(_Connect._Connect-Type).

            CASE cConnType:
                WHEN "SELF"  THEN iSelfConn  = iSelfConn  + 1.
                WHEN "BATCH" THEN iBatchConn = iBatchConn + 1.
                WHEN "BIW"   THEN iBIW       = iBIW       + 1.
                WHEN "AIW"   THEN iAIW       = iAIW       + 1.
                WHEN "WDOG"  THEN iWDOG      = iWDOG      + 1.
                WHEN "APW"   THEN iAPW       = iAPW       + 1.
                OTHERWISE iRemoteConn = iRemoteConn + 1.
            END CASE.
        END.
    END.

    /* % conexões ativas vs. -n */
    IF giParamN <> ? AND giParamN > 0 THEN
        dActVsMaxPct = ROUND(iActive / giParamN * 100, 2).

    /* ============== Montagem da seção JSON ===================== */

    gcSecCon = ""
        + fnMetric("active_connections",
                   fnJsonInt(iActive), "connections",
                   "healthy", "", "",
                   "COUNT(_Connect WHERE _Connect-Name <> '')", "")

        + "," + fnMetric("max_connections",
                   fnJsonInt(giParamN), "connections",
                   "healthy", "", "",
                   "DBPARAM(1) -n", "")

        + "," + fnMetric("active_vs_max_percent",
                   fnJsonNum(dActVsMaxPct), "percent",
                   fnClassLow(dActVsMaxPct, 80, 95),
                   "80-94", ">=95",
                   "active / -n * 100", "")

        + "," + fnMetric("self_connections",
                   fnJsonInt(iSelfConn), "connections",
                   "healthy", "", "",
                   "_Connect-Type = 'SELF'", "")

        + "," + fnMetric("remote_connections",
                   fnJsonInt(iRemoteConn), "connections",
                   "healthy", "", "",
                   "_Connect-Type <> SELF/BATCH", "")

        + "," + fnMetric("batch_connections",
                   fnJsonInt(iBatchConn), "connections",
                   "healthy", "", "",
                   "_Connect-Type = 'BATCH'", "")

        + "," + fnMetric("idle_sessions_over_30min",
                   "null", "sessions",
                   "unknown", ">5", ">20",
                   "_Connect (sem campo last-activity)",
                   "OE 12.2 não expõe last-activity timestamp em _Connect; requer instrumentação adicional.")

        + "," + fnMetric("connection_errors_per_hour",
                   "null", "errors/hour",
                   "unknown", ">0", ">10",
                   "log de banco / OEM",
                   "Depende de parsing do arquivo .lg externo.")

        + "," + fnMetric("appserver_available_agents",
                   "null", "agents",
                   "unknown", "<5", "<2",
                   "OEM/Pulse/asbman",
                   "Métrica externa: requer integração com OEM ou comando asbman.")

        + "," + fnMetric("nameserver_availability",
                   "null", "boolean",
                   "unknown", "", "",
                   "OEM/nsman",
                   "Métrica externa: requer integração com OEM ou comando nsman.")

        /* ============== Processos de serviço do banco ================ */
        + "," + fnMetric("biw_process",
                   fnJsonInt(iBIW), "processes",
                   IF iBIW > 0 THEN "healthy" ELSE "warning",
                   "", "",
                   "_Connect WHERE _Connect-Type = BIW",
                   "Before Image Writer — deve estar ativo em bancos multi-user.")

        + "," + fnMetric("aiw_process",
                   fnJsonInt(iAIW), "processes",
                   "healthy", "", "",
                   "_Connect WHERE _Connect-Type = AIW",
                   "After Image Writer — ativo quando AI está habilitado.")

        + "," + fnMetric("wdog_process",
                   fnJsonInt(iWDOG), "processes",
                   IF iWDOG > 0 THEN "healthy" ELSE "warning",
                   "", "",
                   "_Connect WHERE _Connect-Type = WDOG",
                   "Watchdog — monitora processos do banco.")

        + "," + fnMetric("apw_process",
                   fnJsonInt(iAPW), "processes",
                   "healthy", "", "",
                   "_Connect WHERE _Connect-Type = APW",
                   "Async Page Writer — escreve páginas sujas em background.").
END PROCEDURE.


/* ====================================================================
   pCollectServices — Status de Serviços do Ecossistema
   --------------------------------------------------------------------
   Estes itens não são, em sua maioria, derivados de VSTs.
   Estrutura preparada para receber valores futuros via integração
   externa (asbman, nsman, OEM, ssh-probes).
   ==================================================================== */
PROCEDURE pCollectServices:

    /* O simples fato de termos chegado aqui significa que conseguimos
       conectar e ler o _DbStatus, ou seja, o banco está online. */
    DEFINE VARIABLE lDbOnline AS LOGICAL NO-UNDO.
    lDbOnline = (gcDbStatus = "online").

    gcSecSvc = ""
        + fnMetric("database_online",
                   IF lDbOnline THEN "true" ELSE "false",
                   "boolean",
                   IF lDbOnline THEN "healthy" ELSE "critical",
                   "", "",
                   "_DbStatus / connectivity",
                   "Considerado online quando _DbStatus pôde ser lido.")

        + "," + fnMetric("appserver_status",
                   "null", "string",
                   "unknown", "", "",
                   "asbman / OEM",
                   "Métrica externa, fora do escopo das VSTs.")

        + "," + fnMetric("nameserver_status",
                   "null", "string",
                   "unknown", "", "",
                   "nsman / OEM",
                   "Métrica externa, fora do escopo das VSTs.")

        + "," + fnMetric("listener_status",
                   "null", "string",
                   "unknown", "", "",
                   "proutil / netstat",
                   "Métrica externa, requer probe TCP.").
END PROCEDURE.


/* ====================================================================
   pCollectServers — Brokers, Servers e Atividade
   --------------------------------------------------------------------
   VSTs:
     _Servers    — lista de brokers e servidores ativos, com tipo
                   (4GL, SQL, Login, Broker), PID, porta, protocolo,
                   usuários correntes/máximos, logins e pending.
     _ActServer  — atividade de servidores: bytes/mensagens/records
                   enviados e recebidos, time slices.

   Os servidores são classificados por _Server-Type para separar
   4GL de SQL e gerar métricas comparativas.
   ==================================================================== */
PROCEDURE pCollectServers:

    /* Contadores totais */
    DEFINE VARIABLE iTotalBrokers   AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iTotalServers   AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iTotalCurrUsers AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iTotalMaxUsers  AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iTotalPending   AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iTotalLogins    AS INT64   NO-UNDO INITIAL 0.

    /* Contadores por tipo — 4GL */
    DEFINE VARIABLE i4glServers     AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE i4glCurrUsers   AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE i4glMaxUsers    AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE i4glLogins      AS INT64   NO-UNDO INITIAL 0.
    DEFINE VARIABLE i4glPending     AS INTEGER NO-UNDO INITIAL 0.

    /* Contadores por tipo — SQL */
    DEFINE VARIABLE iSqlServers     AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iSqlCurrUsers   AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iSqlMaxUsers    AS INTEGER NO-UNDO INITIAL 0.
    DEFINE VARIABLE iSqlLogins      AS INT64   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iSqlPending     AS INTEGER NO-UNDO INITIAL 0.

    /* Contadores de atividade (_ActServer) */
    DEFINE VARIABLE dTotalBytesRec  AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE dTotalBytesSent AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE dTotalMsgRec    AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE dTotalMsgSent   AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE dTotalRecRec    AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE dTotalRecSent   AS DECIMAL NO-UNDO INITIAL 0.
    DEFINE VARIABLE dTotalQryRec    AS DECIMAL NO-UNDO INITIAL 0.

    /* Auxiliares */
    DEFINE VARIABLE cType           AS CHARACTER NO-UNDO.
    DEFINE VARIABLE iCurr           AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iMax            AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iPend           AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iLog            AS INT64     NO-UNDO.
    DEFINE VARIABLE cBrokerPorts    AS CHARACTER NO-UNDO INITIAL "".

    /* ============== _Servers: brokers e servidores =====================
       _Server-Type contém o tipo: "Broker", "Login", "4GL", "SQL",
       "4GLSrv", "SQLSrv", "Serve" etc. — varia entre versões.
       Classificamos: se contém "SQL" é SQL, se contém "4GL" ou "Serve"
       é 4GL, "Broker"/"Login" são brokers. ========================== */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _Servers NO-LOCK:
            cType = STRING(_Server-Type) NO-ERROR.
            iCurr = INTEGER(_Server-CurrUsers) NO-ERROR.
            iMax  = INTEGER(_Server-MaxUsers)  NO-ERROR.
            iPend = INTEGER(_Server-PendConn)  NO-ERROR.
            iLog  = INT64(_Server-Logins)      NO-ERROR.

            IF iCurr = ? THEN iCurr = 0.
            IF iMax  = ? THEN iMax  = 0.
            IF iPend = ? THEN iPend = 0.
            IF iLog  = ? THEN iLog  = 0.

            /* Classifica como Broker ou Server */
            IF cType = "Broker" OR cType = "Login" THEN DO:
                iTotalBrokers = iTotalBrokers + 1.
                /* Coleta portas dos brokers para info */
                IF _Server-PortNum > 0 THEN DO:
                    IF cBrokerPorts > "" THEN cBrokerPorts = cBrokerPorts + ",".
                    cBrokerPorts = cBrokerPorts + STRING(_Server-PortNum)
                                 + "(" + cType + "/" + _Server-Protocol + ")".
                END.
            END.
            ELSE DO:
                iTotalServers = iTotalServers + 1.

                /* Classifica 4GL vs SQL */
                IF INDEX(cType, "SQL") > 0 THEN DO:
                    iSqlServers   = iSqlServers   + 1.
                    iSqlCurrUsers = iSqlCurrUsers + iCurr.
                    iSqlMaxUsers  = iSqlMaxUsers  + iMax.
                    iSqlLogins    = iSqlLogins    + iLog.
                    iSqlPending   = iSqlPending   + iPend.
                END.
                ELSE DO:
                    i4glServers   = i4glServers   + 1.
                    i4glCurrUsers = i4glCurrUsers + iCurr.
                    i4glMaxUsers  = i4glMaxUsers  + iMax.
                    i4glLogins    = i4glLogins    + iLog.
                    i4glPending   = i4glPending   + iPend.
                END.
            END.

            iTotalCurrUsers = iTotalCurrUsers + iCurr.
            iTotalMaxUsers  = iTotalMaxUsers  + iMax.
            iTotalPending   = iTotalPending   + iPend.
            iTotalLogins    = iTotalLogins    + iLog.
        END.
    END.

    /* ============== _ActServer: atividade de servidores =============== */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _ActServer NO-LOCK:
            dTotalBytesRec  = dTotalBytesRec  + DECIMAL(_Server-ByteRec)  NO-ERROR.
            dTotalBytesSent = dTotalBytesSent + DECIMAL(_Server-ByteSent) NO-ERROR.
            dTotalMsgRec    = dTotalMsgRec    + DECIMAL(_Server-MsgRec)   NO-ERROR.
            dTotalMsgSent   = dTotalMsgSent   + DECIMAL(_Server-MsgSent)  NO-ERROR.
            dTotalRecRec    = dTotalRecRec    + DECIMAL(_Server-RecRec)   NO-ERROR.
            dTotalRecSent   = dTotalRecSent   + DECIMAL(_Server-RecSent)  NO-ERROR.
            dTotalQryRec    = dTotalQryRec    + DECIMAL(_Server-QryRec)   NO-ERROR.
        END.
    END.

    /* ============== Montagem da seção JSON ========================== */

    gcSecSrv = ""
        /* --- Totais --- */
        + fnMetric("total_brokers",
                   fnJsonInt(iTotalBrokers), "brokers",
                   "healthy", "", "",
                   "_Servers WHERE Type = Broker/Login",
                   "Total de processos broker ativos.")

        + "," + fnMetric("total_servers",
                   fnJsonInt(iTotalServers), "servers",
                   "healthy", "", "",
                   "_Servers WHERE Type <> Broker/Login",
                   "Total de processos server ativos.")

        + "," + fnMetric("broker_ports",
                   fnJsonStr(cBrokerPorts), "info",
                   "healthy", "", "",
                   "_Servers._Server-PortNum",
                   "Portas dos brokers: porta(tipo/protocolo).")

        + "," + fnMetric("total_current_users",
                   fnJsonInt(iTotalCurrUsers), "users",
                   "healthy", "", "",
                   "SUM(_Servers._Server-CurrUsers)",
                   "Usuários conectados em todos os servidores.")

        + "," + fnMetric("total_max_users",
                   fnJsonInt(iTotalMaxUsers), "users",
                   "healthy", "", "",
                   "SUM(_Servers._Server-MaxUsers)",
                   "Capacidade máxima de todos os servidores.")

        + "," + fnMetric("total_pending_connections",
                   fnJsonInt(iTotalPending), "connections",
                   fnClassLow(iTotalPending, 5, 20),
                   "5-20", ">20",
                   "SUM(_Servers._Server-PendConn)",
                   "Conexões pendentes (aguardando server).")

        + "," + fnMetric("total_logins",
                   fnJsonInt(iTotalLogins), "logins",
                   "healthy", "", "",
                   "SUM(_Servers._Server-Logins)",
                   "Total de logins desde startup.")

        /* --- 4GL --- */
        + "," + fnMetric("servers_4gl",
                   fnJsonInt(i4glServers), "servers",
                   "healthy", "", "",
                   "_Servers WHERE Type contains 4GL/Serve",
                   "Servidores 4GL/ABL ativos.")

        + "," + fnMetric("users_4gl_current",
                   fnJsonInt(i4glCurrUsers), "users",
                   "healthy", "", "",
                   "SUM(_Server-CurrUsers) WHERE 4GL",
                   "Usuários conectados em servidores 4GL.")

        + "," + fnMetric("users_4gl_max",
                   fnJsonInt(i4glMaxUsers), "users",
                   "healthy", "", "",
                   "SUM(_Server-MaxUsers) WHERE 4GL",
                   "Capacidade máxima dos servidores 4GL.")

        + "," + fnMetric("logins_4gl",
                   fnJsonInt(i4glLogins), "logins",
                   "healthy", "", "",
                   "SUM(_Server-Logins) WHERE 4GL",
                   "Logins 4GL desde startup.")

        + "," + fnMetric("pending_4gl",
                   fnJsonInt(i4glPending), "connections",
                   "healthy", "", "",
                   "SUM(_Server-PendConn) WHERE 4GL", "")

        /* --- SQL --- */
        + "," + fnMetric("servers_sql",
                   fnJsonInt(iSqlServers), "servers",
                   "healthy", "", "",
                   "_Servers WHERE Type contains SQL",
                   "Servidores SQL ativos.")

        + "," + fnMetric("users_sql_current",
                   fnJsonInt(iSqlCurrUsers), "users",
                   "healthy", "", "",
                   "SUM(_Server-CurrUsers) WHERE SQL",
                   "Usuários conectados em servidores SQL.")

        + "," + fnMetric("users_sql_max",
                   fnJsonInt(iSqlMaxUsers), "users",
                   "healthy", "", "",
                   "SUM(_Server-MaxUsers) WHERE SQL",
                   "Capacidade máxima dos servidores SQL.")

        + "," + fnMetric("logins_sql",
                   fnJsonInt(iSqlLogins), "logins",
                   "healthy", "", "",
                   "SUM(_Server-Logins) WHERE SQL",
                   "Logins SQL desde startup.")

        + "," + fnMetric("pending_sql",
                   fnJsonInt(iSqlPending), "connections",
                   "healthy", "", "",
                   "SUM(_Server-PendConn) WHERE SQL", "")

        /* --- Atividade (_ActServer) --- */
        + "," + fnMetric("srv_bytes_received",
                   fnJsonNum(dTotalBytesRec), "bytes",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-ByteRec)",
                   "Total de bytes recebidos por todos os servidores.")

        + "," + fnMetric("srv_bytes_sent",
                   fnJsonNum(dTotalBytesSent), "bytes",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-ByteSent)",
                   "Total de bytes enviados por todos os servidores.")

        + "," + fnMetric("srv_messages_received",
                   fnJsonNum(dTotalMsgRec), "messages",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-MsgRec)", "")

        + "," + fnMetric("srv_messages_sent",
                   fnJsonNum(dTotalMsgSent), "messages",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-MsgSent)", "")

        + "," + fnMetric("srv_records_received",
                   fnJsonNum(dTotalRecRec), "records",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-RecRec)", "")

        + "," + fnMetric("srv_records_sent",
                   fnJsonNum(dTotalRecSent), "records",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-RecSent)", "")

        + "," + fnMetric("srv_queries_received",
                   fnJsonNum(dTotalQryRec), "queries",
                   "healthy", "", "",
                   "SUM(_ActServer._Server-QryRec)",
                   "Total de queries recebidas pelos servidores.").
END PROCEDURE.


/* ====================================================================
   pCollectStorage — Estrutura de Blocos e Capacidade
   --------------------------------------------------------------------
   VSTs:
     _DbStatus — DbBlkSize, HiWater, FreeBlks, EmptyBlks, TotalBlks,
                  RMFreeBlks, NumAreas, NumLocks, MostLocks, BiSize

   Métricas calculadas (best practices Progress):
     - Blocos em uso       = HiWater - FreeBlks
     - Cap. reutilizável   = FreeBlks * DbBlkSize (em GB)
     - Cap. não formatada  = EmptyBlks * DbBlkSize (em GB)
     - % livre reutilizável = (FreeBlks / HiWater) * 100
     - % consumido até HWM = ((HiWater - FreeBlks) / HiWater) * 100
     - Tamanho total DB    = TotalBlks * DbBlkSize (em GB)
     - Tamanho até HWM     = (HiWater - FreeBlks) * DbBlkSize (em GB)
     - % alocado em -B     = -B / TotalBlks * 100

   Referência: documentação Progress OpenEdge RDBMS Administration.
   ==================================================================== */
PROCEDURE pCollectStorage:

    /* Campos diretos do _DbStatus */
    DEFINE VARIABLE iDbBlkSz    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iHiWater    AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iFreeBlks   AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iEmptyBlks  AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iTotalBlks  AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iRMFreeBlks AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE iNumAreas   AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iNumLocks   AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMostLocks  AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBiSize     AS INT64   NO-UNDO INITIAL ?.

    /* Cálculos derivados */
    DEFINE VARIABLE iBlocksInUse     AS INT64   NO-UNDO INITIAL ?.
    DEFINE VARIABLE dDbSizeGB        AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dUsedSizeGB      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dFreeReuseGB     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dEmptyCapGB      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dFreeReusePct    AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dConsumedPct     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBiSizeGB        AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBufAllocPct     AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBuf1AllocPct    AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBufAllocGB      AS DECIMAL NO-UNDO INITIAL ?.
    DEFINE VARIABLE dBuf1AllocGB     AS DECIMAL NO-UNDO INITIAL ?.

    /* Constante para conversão bytes -> GB */
    DEFINE VARIABLE dGB AS DECIMAL NO-UNDO INITIAL 1073741824.  /* 1024^3 */

    /* Features do banco via _Database-Feature */
    DEFINE VARIABLE lLargeFiles      AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE lLargeKeys       AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE l64bitDbkeys     AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE l64bitSeqs       AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE lEncryption      AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE lAuditing        AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE lReplication     AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE lMultiTenancy    AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE lCDC             AS LOGICAL   NO-UNDO INITIAL ?.
    DEFINE VARIABLE cFeatureName     AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cFeatureActive   AS CHARACTER NO-UNDO.

    /* Monitoramento de áreas/extents */
    DEFINE VARIABLE iAreasAtRisk     AS INTEGER   NO-UNDO INITIAL 0.
    DEFINE VARIABLE cAreasAtRisk     AS CHARACTER NO-UNDO INITIAL "".
    DEFINE VARIABLE iAreasFixedLast  AS INTEGER   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iAreasVarLast    AS INTEGER   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iTotalAreas      AS INTEGER   NO-UNDO INITIAL 0.
    DEFINE VARIABLE iMaxExtNum       AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iLastExtType     AS INTEGER   NO-UNDO.
    DEFINE VARIABLE dAreaFreePct     AS DECIMAL   NO-UNDO.
    DEFINE VARIABLE cAreaName        AS CHARACTER NO-UNDO.
    DEFINE VARIABLE iAreaNum         AS INTEGER   NO-UNDO.
    DEFINE VARIABLE iAreaFree        AS INT64     NO-UNDO.
    DEFINE VARIABLE iAreaTotal       AS INT64     NO-UNDO.

    /* ============== _DbStatus: leitura dos campos de blocos ========= */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _DbStatus NO-LOCK NO-ERROR.
        IF AVAILABLE _DbStatus THEN DO:
            iDbBlkSz    = INTEGER(_DbStatus-DbBlkSize) NO-ERROR.
            iHiWater    = INT64(_DbStatus-HiWater)     NO-ERROR.
            iFreeBlks   = INT64(_DbStatus-FreeBlks)    NO-ERROR.
            iEmptyBlks  = INT64(_DbStatus-EmptyBlks)   NO-ERROR.
            iTotalBlks  = INT64(_DbStatus-TotalBlks)   NO-ERROR.
            iRMFreeBlks = INT64(_DbStatus-RMFreeBlks)  NO-ERROR.
            iNumAreas   = INTEGER(_DbStatus-NumAreas)  NO-ERROR.
            iNumLocks   = INTEGER(_DbStatus-NumLocks)  NO-ERROR.
            iMostLocks  = INTEGER(_DbStatus-MostLocks) NO-ERROR.
            iBiSize     = INT64(_DbStatus-BiSize)      NO-ERROR.
        END.
        ELSE RUN pAddError("storage",
                           "VST _DbStatus indisponível para métricas de blocos",
                           "_DbStatus", "warning").
    END.

    /* ============== Cálculos derivados (best practices Progress) ====
       Todas as fórmulas protegidas contra divisão por zero e valores
       nulos. Se HiWater ou TotalBlks for 0/?, o percentual fica ?. == */

    /* Normaliza campos nulos para 0 — evita null no JSON que causa
       erro de preprocessing no Zabbix ("no data matches path"). */
    IF iHiWater    = ? THEN iHiWater    = 0.
    IF iFreeBlks   = ? THEN iFreeBlks   = 0.
    IF iEmptyBlks  = ? THEN iEmptyBlks  = 0.
    IF iTotalBlks  = ? THEN iTotalBlks  = 0.
    IF iRMFreeBlks = ? THEN iRMFreeBlks = 0.
    IF iDbBlkSz    = ? THEN iDbBlkSz    = 0.
    IF iBiSize     = ? THEN iBiSize     = 0.

    /* Blocos efetivamente em uso = HiWater - FreeBlks */
    iBlocksInUse = iHiWater - iFreeBlks.
    IF iBlocksInUse < 0 THEN iBlocksInUse = 0.

    /* Tamanho total do banco em GB = TotalBlks * DbBlkSize / 1024^3 */
    IF iTotalBlks > 0 AND iDbBlkSz > 0 THEN
        dDbSizeGB = ROUND((iTotalBlks * iDbBlkSz) / dGB, 4).
    ELSE dDbSizeGB = 0.

    /* Tamanho ocupado até o HWM em GB */
    IF iDbBlkSz > 0 THEN
        dUsedSizeGB = ROUND((iBlocksInUse * iDbBlkSz) / dGB, 4).
    ELSE dUsedSizeGB = 0.

    /* Espaço livre reutilizável em GB = FreeBlks * DbBlkSize / 1024^3 */
    IF iDbBlkSz > 0 THEN
        dFreeReuseGB = ROUND((iFreeBlks * iDbBlkSz) / dGB, 4).
    ELSE dFreeReuseGB = 0.

    /* Espaço ainda não formatado em GB = EmptyBlks * DbBlkSize / 1024^3 */
    IF iDbBlkSz > 0 THEN
        dEmptyCapGB = ROUND((iEmptyBlks * iDbBlkSz) / dGB, 4).
    ELSE dEmptyCapGB = 0.

    /* % livre reutilizável = (FreeBlks / HiWater) * 100 */
    IF iHiWater > 0 THEN
        dFreeReusePct = ROUND((iFreeBlks / iHiWater) * 100, 2).
    ELSE dFreeReusePct = 0.

    /* % consumido até o HWM = ((HiWater - FreeBlks) / HiWater) * 100 */
    IF iHiWater > 0 THEN
        dConsumedPct = ROUND((iBlocksInUse / iHiWater) * 100, 2).
    ELSE dConsumedPct = 0.

    /* Tamanho do BI em GB (BiSize é int64, provavelmente em bytes) */
    IF iBiSize > 0 THEN
        dBiSizeGB = ROUND(iBiSize / dGB, 4).
    ELSE dBiSizeGB = 0.

    /* % do banco alocado em memória via -B
       -B configura o número de buffers no buffer pool.
       Cada buffer = 1 bloco do banco. Se temos TotalBlks blocos,
       o % alocado = (-B / TotalBlks) * 100. */
    IF giParamB <> ? AND iTotalBlks > 0 THEN
        dBufAllocPct = ROUND((giParamB / iTotalBlks) * 100, 2).
    ELSE dBufAllocPct = 0.

    /* % do banco alocado em memória via -B1 (alternate buffer pool) */
    IF giParamB1 <> ? AND iTotalBlks > 0 THEN
        dBuf1AllocPct = ROUND((giParamB1 / iTotalBlks) * 100, 2).
    ELSE dBuf1AllocPct = 0.

    /* Tamanho em GB alocado via -B = -B * DbBlkSize / 1024^3 */
    IF giParamB <> ? AND iDbBlkSz > 0 THEN
        dBufAllocGB = ROUND((giParamB * iDbBlkSz) / dGB, 4).
    ELSE dBufAllocGB = 0.

    /* Tamanho em GB alocado via -B1 = -B1 * DbBlkSize / 1024^3 */
    IF giParamB1 <> ? AND iDbBlkSz > 0 THEN
        dBuf1AllocGB = ROUND((giParamB1 * iDbBlkSz) / dGB, 4).
    ELSE dBuf1AllocGB = 0.

    /* ============== Database Features via _Database-Feature ==========
       VST definitiva que lista todas as features do banco com status.
       _DBFeature_Active = "1" significa habilitado.
       IDs conhecidos:
         5  = Large Files       9  = 64 Bit DBKEYS
         10 = Large Keys        11 = 64 Bit Sequences
         6  = Database Auditing 13 = Encryption
         1  = OpenEdge Replication  14 = Multi-tenancy
         27 = Change Data Capture
       ================================================================ */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _Database-Feature NO-LOCK:
            cFeatureName   = STRING(_DBFeature_Name)   NO-ERROR.
            cFeatureActive = STRING(_DBFeature_Active)  NO-ERROR.

            CASE STRING(_DBFeature-ID):
                WHEN "5"  THEN lLargeFiles    = (cFeatureActive = "1").
                WHEN "9"  THEN l64bitDbkeys   = (cFeatureActive = "1").
                WHEN "10" THEN lLargeKeys     = (cFeatureActive = "1").
                WHEN "11" THEN l64bitSeqs     = (cFeatureActive = "1").
                WHEN "6"  THEN lAuditing      = (cFeatureActive = "1").
                WHEN "13" THEN lEncryption    = (cFeatureActive = "1").
                WHEN "1"  THEN lReplication   = (cFeatureActive = "1").
                WHEN "14" THEN lMultiTenancy  = (cFeatureActive = "1").
                WHEN "27" THEN lCDC           = (cFeatureActive = "1").
            END CASE.
        END.
    END.

    /* ============== Monitoramento de áreas e extents =================
       Para cada área de dados (tipo 6, number > 6):
       1) Obtém o % livre via _AreaStatus (Freenum / Totblocks)
       2) Encontra o último extent via _AreaExtent (maior _Extent-number)
       3) Verifica se o último extent é fixo (type=37) ou variável (type=5)
       4) Se fixo E % livre < 5%, marca como "at risk" — a área não pode
          crescer além do tamanho alocado nos extents fixos.
       5) Se variável E % livre < 5%, marca com aviso — o extent pode
          crescer mas pode haver limitação de disco.
       Tipo de extents: 37=fixo dados, 5=variável dados, 4=variável AI,
                         3=variável BI. ================================ */
    DO ON ERROR UNDO, LEAVE:
        FOR EACH _AreaStatus NO-LOCK
            WHERE _AreaStatus-Areanum > 6:

            iAreaNum   = _AreaStatus-Areanum.
            cAreaName  = STRING(_AreaStatus-Areaname) NO-ERROR.
            iAreaFree  = INT64(_AreaStatus-Freenum)   NO-ERROR.
            iAreaTotal = INT64(_AreaStatus-Totblocks)  NO-ERROR.

            IF iAreaFree = ? THEN iAreaFree = 0.
            IF iAreaTotal = ? OR iAreaTotal = 0 THEN NEXT.

            iTotalAreas = iTotalAreas + 1.
            dAreaFreePct = (iAreaFree / iAreaTotal) * 100.

            /* Encontra o último extent desta área */
            iMaxExtNum  = 0.
            iLastExtType = 0.
            FOR EACH _AreaExtent NO-LOCK
                WHERE _AreaExtent._Area-number = iAreaNum:
                IF _AreaExtent._Extent-number > iMaxExtNum THEN
                    ASSIGN
                        iMaxExtNum   = _AreaExtent._Extent-number
                        iLastExtType = INTEGER(_AreaExtent._Extent-type) NO-ERROR.
            END.

            /* Classifica: último extent fixo (37) ou variável (5) */
            IF iLastExtType = 5 OR iLastExtType = 4 THEN
                iAreasVarLast = iAreasVarLast + 1.
            ELSE
                iAreasFixedLast = iAreasFixedLast + 1.

            /* Alerta: último extent FIXO com < 5% livre = risco alto */
            IF iLastExtType <> 5 AND iLastExtType <> 4 AND dAreaFreePct < 5 THEN DO:
                iAreasAtRisk = iAreasAtRisk + 1.
                IF cAreasAtRisk > "" THEN cAreasAtRisk = cAreasAtRisk + ", ".
                cAreasAtRisk = cAreasAtRisk + cAreaName
                    + " (" + STRING(ROUND(dAreaFreePct, 1)) + "% free, ext " + STRING(iMaxExtNum) + " fixed)".
            END.

            /* Alerta: último extent VARIÁVEL com < 5% livre = disco pode estar cheio */
            IF (iLastExtType = 5 OR iLastExtType = 4) AND dAreaFreePct < 5 THEN DO:
                iAreasAtRisk = iAreasAtRisk + 1.
                IF cAreasAtRisk > "" THEN cAreasAtRisk = cAreasAtRisk + ", ".
                cAreasAtRisk = cAreasAtRisk + cAreaName
                    + " (" + STRING(ROUND(dAreaFreePct, 1)) + "% free, ext " + STRING(iMaxExtNum) + " variable)".
            END.
        END.
    END.

    /* ============== Montagem da seção JSON ========================= */

    gcSecStg = ""
        /* --- Campos diretos _DbStatus --- */
        + fnMetric("db_block_size_status",
                   fnJsonInt(iDbBlkSz), "bytes",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-DbBlkSize",
                   "Tamanho do bloco do banco em bytes.")

        + "," + fnMetric("total_blocks",
                   fnJsonInt(iTotalBlks), "blocks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-TotalBlks",
                   "Total de blocos alocados no banco.")

        + "," + fnMetric("hi_water_mark",
                   fnJsonInt(iHiWater), "blocks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-HiWater",
                   "High water mark — último bloco utilizado.")

        + "," + fnMetric("free_blocks_reusable",
                   fnJsonInt(iFreeBlks), "blocks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-FreeBlks",
                   "Blocos livres reutilizáveis (já foram usados e liberados).")

        + "," + fnMetric("empty_blocks_unformatted",
                   fnJsonInt(iEmptyBlks), "blocks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-EmptyBlks",
                   "Blocos vazios ainda não formatados (após o HWM).")

        + "," + fnMetric("rm_free_blocks",
                   fnJsonInt(iRMFreeBlks), "blocks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-RMFreeBlks",
                   "Blocos livres no Record Manager (RM).")

        + "," + fnMetric("blocks_in_use",
                   fnJsonInt(iBlocksInUse), "blocks",
                   "healthy", "", "",
                   "HiWater - FreeBlks",
                   "Blocos efetivamente em uso (calculado).")

        /* --- Tamanhos em GB --- */
        + "," + fnMetric("db_size_total_gb",
                   fnJsonNum(dDbSizeGB), "GB",
                   "healthy", "", "",
                   "TotalBlks * DbBlkSize / 1024^3",
                   "Tamanho total do banco em GB.")

        + "," + fnMetric("db_size_used_gb",
                   fnJsonNum(dUsedSizeGB), "GB",
                   "healthy", "", "",
                   "(HiWater - FreeBlks) * DbBlkSize / 1024^3",
                   "Espaço ocupado até o HWM em GB.")

        + "," + fnMetric("db_free_reusable_gb",
                   fnJsonNum(dFreeReuseGB), "GB",
                   "healthy", "", "",
                   "FreeBlks * DbBlkSize / 1024^3",
                   "Espaço livre reutilizável em GB.")

        + "," + fnMetric("db_empty_unformatted_gb",
                   fnJsonNum(dEmptyCapGB), "GB",
                   "healthy", "", "",
                   "EmptyBlks * DbBlkSize / 1024^3",
                   "Espaço vazio não formatado em GB.")

        + "," + fnMetric("bi_size_gb",
                   fnJsonNum(dBiSizeGB), "GB",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-BiSize / 1024^3",
                   "Tamanho do BI (Before Image) em GB via _DbStatus.")

        /* --- Percentuais --- */
        + "," + fnMetric("pct_free_reusable",
                   fnJsonNum(dFreeReusePct), "percent",
                   fnClassHigh(dFreeReusePct, 10, 5),
                   "5-10", "<5",
                   "(FreeBlks / HiWater) * 100",
                   "Percentual livre reutilizável. <5% indica necessidade de compactação ou extensão.")

        + "," + fnMetric("pct_consumed_hwm",
                   fnJsonNum(dConsumedPct), "percent",
                   fnClassLow(dConsumedPct, 90, 95),
                   "90-95", ">95",
                   "((HiWater - FreeBlks) / HiWater) * 100",
                   "Percentual consumido até o HWM. >95% indica banco quase cheio.")

        + "," + fnMetric("pct_buffer_alloc",
                   fnJsonNum(dBufAllocPct), "percent",
                   "healthy", "", "",
                   "(-B / TotalBlks) * 100",
                   "Percentual do banco alocado em memória via -B. Requer DBPARAM local.")

        + "," + fnMetric("pct_buffer_B1_alloc",
                   fnJsonNum(dBuf1AllocPct), "percent",
                   "healthy", "", "",
                   "(-B1 / TotalBlks) * 100",
                   "Percentual do banco alocado em alternate buffer pool -B1.")

        + "," + fnMetric("buffer_alloc_gb",
                   fnJsonNum(dBufAllocGB), "GB",
                   "healthy", "", "",
                   "(-B * DbBlkSize) / 1024^3",
                   "Memória alocada pelo buffer pool -B em GB.")

        + "," + fnMetric("buffer_B1_alloc_gb",
                   fnJsonNum(dBuf1AllocGB), "GB",
                   "healthy", "", "",
                   "(-B1 * DbBlkSize) / 1024^3",
                   "Memória alocada pelo alternate buffer pool -B1 em GB.")

        + "," + fnMetric("startup_B_blocks",
                   fnJsonInt(giParamB), "blocks",
                   "healthy", "", "",
                   "DBPARAM -B",
                   "Blocos alocados em memória via -B.")

        + "," + fnMetric("startup_B1_blocks",
                   fnJsonInt(giParamB1), "blocks",
                   "healthy", "", "",
                   "DBPARAM -B1",
                   "Blocos alocados em alternate buffer pool via -B1.")

        /* --- Informações complementares de _DbStatus --- */
        + "," + fnMetric("num_areas",
                   fnJsonInt(iNumAreas), "areas",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-NumAreas",
                   "Número de áreas de armazenamento do banco.")

        + "," + fnMetric("num_locks_current",
                   fnJsonInt(iNumLocks), "locks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-NumLocks",
                   "Número de locks atuais via _DbStatus.")

        + "," + fnMetric("most_locks_ever",
                   fnJsonInt(iMostLocks), "locks",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-MostLocks",
                   "Pico de locks simultâneos desde o startup.")

        /* --- Database Features (via _Database-Feature) --- */
        + "," + fnMetric("large_files_enabled",
                   IF lLargeFiles = TRUE THEN "true"
                   ELSE IF lLargeFiles = FALSE THEN "false"
                   ELSE "null",
                   "boolean",
                   IF lLargeFiles = TRUE THEN "healthy"
                   ELSE IF lLargeFiles = FALSE THEN "warning"
                   ELSE "unknown",
                   "", "",
                   "_Database-Feature ID=5",
                   "Permite extents > 2GB. Habilitar: proutil <db> -C enablelargefiles.")

        + "," + fnMetric("64bit_dbkeys_enabled",
                   IF l64bitDbkeys = TRUE THEN "true"
                   ELSE IF l64bitDbkeys = FALSE THEN "false"
                   ELSE "null",
                   "boolean",
                   IF l64bitDbkeys THEN "healthy" ELSE "healthy",
                   "", "",
                   "_Database-Feature ID=9", "")

        + "," + fnMetric("large_keys_enabled",
                   IF lLargeKeys = TRUE THEN "true"
                   ELSE IF lLargeKeys = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=10", "")

        + "," + fnMetric("64bit_sequences_enabled",
                   IF l64bitSeqs = TRUE THEN "true"
                   ELSE IF l64bitSeqs = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=11", "")

        + "," + fnMetric("encryption_enabled",
                   IF lEncryption = TRUE THEN "true"
                   ELSE IF lEncryption = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=13", "")

        + "," + fnMetric("auditing_enabled",
                   IF lAuditing = TRUE THEN "true"
                   ELSE IF lAuditing = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=6", "")

        + "," + fnMetric("replication_enabled",
                   IF lReplication = TRUE THEN "true"
                   ELSE IF lReplication = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=1", "")

        + "," + fnMetric("multitenancy_enabled",
                   IF lMultiTenancy = TRUE THEN "true"
                   ELSE IF lMultiTenancy = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=14", "")

        + "," + fnMetric("cdc_enabled",
                   IF lCDC = TRUE THEN "true"
                   ELSE IF lCDC = FALSE THEN "false"
                   ELSE "null",
                   "boolean", "healthy", "", "",
                   "_Database-Feature ID=27",
                   "Change Data Capture.")

        /* --- Monitoramento de áreas/extents --- */
        + "," + fnMetric("areas_at_risk_count",
                   fnJsonInt(iAreasAtRisk), "areas",
                   IF iAreasAtRisk = 0 THEN "healthy"
                   ELSE "warning",
                   ">0", ">0",
                   "FOR EACH _AreaStatus/_AreaExtent WHERE free < 5% AND last extent",
                   "Áreas com < 5% blocos livres no último extent. 0 = sem risco.")

        + "," + fnMetric("areas_at_risk_names",
                   fnJsonStr(IF cAreasAtRisk = "" THEN "none" ELSE cAreasAtRisk),
                   "info",
                   "healthy", "", "",
                   "áreas identificadas",
                   "Lista das áreas em risco com % livre e tipo do último extent.")

        + "," + fnMetric("areas_with_fixed_last_extent",
                   fnJsonInt(iAreasFixedLast), "areas",
                   "healthy", "", "",
                   "_AreaExtent WHERE last AND type=37",
                   "Áreas cujo último extent é fixo — não crescem automaticamente.")

        + "," + fnMetric("areas_with_variable_last_extent",
                   fnJsonInt(iAreasVarLast), "areas",
                   "healthy", "", "",
                   "_AreaExtent WHERE last AND type IN (4,5)",
                   "Áreas cujo último extent é variável — crescem automaticamente.")

        + "," + fnMetric("monitored_areas_count",
                   fnJsonInt(iTotalAreas), "areas",
                   "healthy", "", "",
                   "COUNT(_AreaStatus WHERE Areanum > 6)", "").
END PROCEDURE.


/* ====================================================================
   pCollectBackup — Status de Backup do Banco
   --------------------------------------------------------------------
   VSTs:
     _DbStatus — _DbStatus-fbDate (full backup), _DbStatus-ibDate
                  (incremental backup), _DbStatus-ibSeq (sequência)
     _MstrBlk  — _MstrBlk-fbdate, _MstrBlk-ibdate (redundantes)

   Calcula "minutos desde o último backup" para triggers de alerta.
   O formato das datas é ctime C: "Sat Oct 28 20:24:16 2023".
   A função fnParseCtime converte para DATETIME para cálculo.
   ==================================================================== */
PROCEDURE pCollectBackup:

    DEFINE VARIABLE cFbDate       AS CHARACTER NO-UNDO INITIAL "".
    DEFINE VARIABLE cIbDate       AS CHARACTER NO-UNDO INITIAL "".
    DEFINE VARIABLE iIbSeq        AS INTEGER   NO-UNDO INITIAL ?.
    DEFINE VARIABLE dtFb          AS DATETIME  NO-UNDO INITIAL ?.
    DEFINE VARIABLE dtIb          AS DATETIME  NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMinSinceFb   AS INT64     NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMinSinceIb   AS INT64     NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMinSinceLast AS INT64     NO-UNDO INITIAL ?.
    DEFINE VARIABLE cLastType     AS CHARACTER NO-UNDO INITIAL "".

    /* ============== _DbStatus: datas de backup ===================== */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _DbStatus NO-LOCK NO-ERROR.
        IF AVAILABLE _DbStatus THEN DO:
            cFbDate = STRING(_DbStatus-fbDate) NO-ERROR.
            cIbDate = STRING(_DbStatus-ibDate) NO-ERROR.
            iIbSeq  = INTEGER(_DbStatus-ibSeq) NO-ERROR.
        END.
    END.

    /* ============== Parse das datas e cálculo de idade ============= */
    IF cFbDate <> ? AND cFbDate <> "" THEN DO:
        dtFb = fnParseCtime(cFbDate).
        IF dtFb <> ? THEN
            iMinSinceFb = INTERVAL(NOW, dtFb, "minutes") NO-ERROR.
    END.

    IF cIbDate <> ? AND cIbDate <> "" THEN DO:
        dtIb = fnParseCtime(cIbDate).
        IF dtIb <> ? THEN
            iMinSinceIb = INTERVAL(NOW, dtIb, "minutes") NO-ERROR.
    END.

    /* Determina o backup mais recente (menor idade) */
    IF iMinSinceFb <> ? AND iMinSinceIb <> ? THEN DO:
        IF iMinSinceFb <= iMinSinceIb THEN
            ASSIGN iMinSinceLast = iMinSinceFb cLastType = "full".
        ELSE
            ASSIGN iMinSinceLast = iMinSinceIb cLastType = "incremental".
    END.
    ELSE IF iMinSinceFb <> ? THEN
        ASSIGN iMinSinceLast = iMinSinceFb cLastType = "full".
    ELSE IF iMinSinceIb <> ? THEN
        ASSIGN iMinSinceLast = iMinSinceIb cLastType = "incremental".

    /* ============== Montagem da seção JSON ========================= */

    gcSecBkp = ""
        + fnMetric("last_full_backup_date",
                   fnJsonStr(cFbDate), "datetime",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-fbDate",
                   "Data/hora do último full backup no formato ctime.")

        + "," + fnMetric("last_incr_backup_date",
                   fnJsonStr(cIbDate), "datetime",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-ibDate",
                   "Data/hora do último incremental backup.")

        + "," + fnMetric("incr_backup_sequence",
                   fnJsonInt(iIbSeq), "sequence",
                   "healthy", "", "",
                   "_DbStatus._DbStatus-ibSeq",
                   "Número sequencial do incremental backup.")

        + "," + fnMetric("minutes_since_full_backup",
                   fnJsonInt(iMinSinceFb), "minutes",
                   IF iMinSinceFb = ? THEN "unknown"
                   ELSE IF iMinSinceFb > 2880 THEN "critical"
                   ELSE IF iMinSinceFb > 1440 THEN "warning"
                   ELSE "healthy",
                   "1440", "2880",
                   "INTERVAL(NOW, fnParseCtime(fbDate), minutes)",
                   "Minutos desde o último full backup. 1440min=24h, 2880min=48h.")

        + "," + fnMetric("minutes_since_incr_backup",
                   fnJsonInt(iMinSinceIb), "minutes",
                   IF iMinSinceIb = ? THEN "unknown"
                   ELSE IF iMinSinceIb > 1440 THEN "critical"
                   ELSE IF iMinSinceIb > 720 THEN "warning"
                   ELSE "healthy",
                   "720", "1440",
                   "INTERVAL(NOW, fnParseCtime(ibDate), minutes)",
                   "Minutos desde o último incremental backup.")

        + "," + fnMetric("minutes_since_any_backup",
                   fnJsonInt(iMinSinceLast), "minutes",
                   IF iMinSinceLast = ? THEN "unknown"
                   ELSE IF iMinSinceLast > 2880 THEN "critical"
                   ELSE IF iMinSinceLast > 1440 THEN "warning"
                   ELSE "healthy",
                   "1440", "2880",
                   "MIN(minutes_since_full, minutes_since_incr)",
                   "Minutos desde qualquer backup (o mais recente).")

        + "," + fnMetric("last_backup_type",
                   fnJsonStr(cLastType), "type",
                   "healthy", "", "",
                   "derivado",
                   "Tipo do backup mais recente: full ou incremental.").
END PROCEDURE.


/* ====================================================================
   pCollectLicense — Informações de Licenciamento
   --------------------------------------------------------------------
   VST:
     _License — conexões ativas/batch/correntes vs. máximos e mínimos,
                e total de usuários licenciados (ValidUsers).
   ==================================================================== */
PROCEDURE pCollectLicense:

    DEFINE VARIABLE iActiveConns AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iBatchConns  AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iCurrConns   AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMaxActive   AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMaxBatch    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMaxCurrent  AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMinActive   AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMinBatch    AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iMinCurrent  AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE iValidUsers  AS INTEGER NO-UNDO INITIAL ?.
    DEFINE VARIABLE dLicUsePct   AS DECIMAL NO-UNDO INITIAL ?.

    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _License NO-LOCK NO-ERROR.
        IF AVAILABLE _License THEN DO:
            iActiveConns = INTEGER(_Lic-ActiveConns) NO-ERROR.
            iBatchConns  = INTEGER(_Lic-BatchConns)  NO-ERROR.
            iCurrConns   = INTEGER(_Lic-CurrConns)   NO-ERROR.
            iMaxActive   = INTEGER(_Lic-MaxActive)   NO-ERROR.
            iMaxBatch    = INTEGER(_Lic-MaxBatch)    NO-ERROR.
            iMaxCurrent  = INTEGER(_Lic-MaxCurrent)  NO-ERROR.
            iMinActive   = INTEGER(_Lic-MinActive)   NO-ERROR.
            iMinBatch    = INTEGER(_Lic-MinBatch)    NO-ERROR.
            iMinCurrent  = INTEGER(_Lic-MinCurrent)  NO-ERROR.
            iValidUsers  = INTEGER(_Lic-ValidUsers)  NO-ERROR.

            /* % de uso da licença = correntes / validUsers * 100 */
            IF iValidUsers <> ? AND iValidUsers > 0 AND iCurrConns <> ? THEN
                dLicUsePct = ROUND(iCurrConns / iValidUsers * 100, 2).
        END.
        ELSE RUN pAddError("license",
                           "VST _License indisponível",
                           "_License", "warning").
    END.

    gcSecLic = ""
        + fnMetric("lic_valid_users",
                   fnJsonInt(iValidUsers), "users",
                   "healthy", "", "",
                   "_License._Lic-ValidUsers",
                   "Total de usuários licenciados.")

        + "," + fnMetric("lic_current_connections",
                   fnJsonInt(iCurrConns), "connections",
                   "healthy", "", "",
                   "_License._Lic-CurrConns",
                   "Conexões correntes consumindo licença.")

        + "," + fnMetric("lic_active_connections",
                   fnJsonInt(iActiveConns), "connections",
                   "healthy", "", "",
                   "_License._Lic-ActiveConns",
                   "Conexões ativas (interativas).")

        + "," + fnMetric("lic_batch_connections",
                   fnJsonInt(iBatchConns), "connections",
                   "healthy", "", "",
                   "_License._Lic-BatchConns",
                   "Conexões batch.")

        + "," + fnMetric("lic_usage_percent",
                   fnJsonNum(dLicUsePct), "percent",
                   fnClassLow(dLicUsePct, 80, 95),
                   "80-94", ">=95",
                   "_Lic-CurrConns / _Lic-ValidUsers * 100",
                   "Percentual de utilização da licença.")

        + "," + fnMetric("lic_max_active",
                   fnJsonInt(iMaxActive), "connections",
                   "healthy", "", "",
                   "_License._Lic-MaxActive",
                   "Pico de conexões ativas desde startup.")

        + "," + fnMetric("lic_max_batch",
                   fnJsonInt(iMaxBatch), "connections",
                   "healthy", "", "",
                   "_License._Lic-MaxBatch",
                   "Pico de conexões batch desde startup.")

        + "," + fnMetric("lic_max_current",
                   fnJsonInt(iMaxCurrent), "connections",
                   "healthy", "", "",
                   "_License._Lic-MaxCurrent",
                   "Pico de conexões totais desde startup.").
END PROCEDURE.


/* ====================================================================
   pCollectConfiguration — Parâmetros de Startup
   --------------------------------------------------------------------
   Fonte: DBPARAM(1) — string com os parâmetros usados na conexão.
   Os valores são parseados pela função fnExtractParam.

   VSTs adicionais:
     _MstrBlk — datas relevantes (criação, último backup)
   ==================================================================== */
PROCEDURE pCollectConfiguration:

    DEFINE VARIABLE cParams       AS CHARACTER NO-UNDO INITIAL "".
    DEFINE VARIABLE cCrDate       AS CHARACTER NO-UNDO INITIAL "".
    DEFINE VARIABLE cOprDate      AS CHARACTER NO-UNDO INITIAL "".

    /* ============== Captura DBPARAM ============================= */
    DO ON ERROR UNDO, LEAVE:
        cParams = DBPARAM(1).
        IF cParams = ? THEN cParams = "".

        ASSIGN
            giParamB    = fnExtractParam(cParams, "-B")
            giParamL    = fnExtractParam(cParams, "-L")
            giParamN    = fnExtractParam(cParams, "-n")
            giParamSpin = fnExtractParam(cParams, "-spin")
            giParamBi   = fnExtractParam(cParams, "-bibufs")
            giParamB1   = fnExtractParam(cParams, "-B1").
    END.

    /* ============== _MstrBlk: datas estruturais ================= */
    DO ON ERROR UNDO, LEAVE:
        FIND FIRST _MstrBlk NO-LOCK NO-ERROR.
        IF AVAILABLE _MstrBlk THEN DO:
            cCrDate  = STRING(_MstrBlk-crdate)  NO-ERROR.
            cOprDate = STRING(_MstrBlk-oprdate) NO-ERROR.
        END.
    END.

    /* ============== Montagem da seção JSON ===================== */

    gcSecCfg = ""
        + fnMetric("startup_B",
                   fnJsonInt(giParamB), "buffers",
                   "healthy", "", "",
                   "DBPARAM -B",
                   "Número de buffers de memória do banco.")

        + "," + fnMetric("startup_L",
                   fnJsonInt(giParamL), "locks",
                   "healthy", "", "",
                   "DBPARAM -L",
                   "Tamanho da lock table.")

        + "," + fnMetric("startup_n",
                   fnJsonInt(giParamN), "users",
                   "healthy", "", "",
                   "DBPARAM -n",
                   "Máximo de conexões simultâneas.")

        + "," + fnMetric("startup_spin",
                   fnJsonInt(giParamSpin), "iterations",
                   "healthy", "", "",
                   "DBPARAM -spin", "")

        + "," + fnMetric("startup_bi",
                   fnJsonInt(giParamBi), "buffers",
                   "healthy", "", "",
                   "DBPARAM -bibufs", "")

        + "," + fnMetric("startup_B1",
                   fnJsonInt(giParamB1), "buffers",
                   "healthy", "", "",
                   "DBPARAM -B1",
                   "Alternate buffer pool (-B1). Usado para tabelas/índices com acesso alternativo.")

        + "," + fnMetric("db_create_date",
                   fnJsonStr(cCrDate), "date",
                   "healthy", "", "",
                   "_MstrBlk._MstrBlk-crdate", "")

        + "," + fnMetric("db_last_open_date",
                   fnJsonStr(cOprDate), "date",
                   "healthy", "", "",
                   "_MstrBlk._MstrBlk-oprdate", "")

        .
END PROCEDURE.


/* ====================================================================
   pBuildHealthSummary — Decide o status agregado de saúde
   --------------------------------------------------------------------
   Regra simples: se houve qualquer erro/aviso registrado em
   gcErrorsJson, eleva para warning. Casos críticos não são detectados
   automaticamente neste agregado — fica a cargo do consumidor (Zabbix)
   aplicar as triggers por métrica usando os campos status individuais.
   ==================================================================== */
PROCEDURE pBuildHealthSummary:
    IF giErrorCount > 0 THEN gcHealthStat = "critical".
    ELSE IF giWarningCount > 0 THEN gcHealthStat = "warning".
    ELSE gcHealthStat = "healthy".

    IF giErrorCount > 0 THEN gcCollectStat = "error".
    ELSE IF giWarningCount > 0 THEN gcCollectStat = "warning".
    ELSE gcCollectStat = "ok".
END PROCEDURE.


/* ====================================================================
   pBuildJson — Monta o JSON final em LONGCHAR a partir das seções
   ==================================================================== */
PROCEDURE pBuildJson:

    DEFINE VARIABLE cTimestamp AS CHARACTER NO-UNDO.

    /* ISO-8601 simplificado: YYYY-MM-DDTHH:MM:SS */
    cTimestamp =
        STRING(YEAR(TODAY),  "9999") + "-" +
        STRING(MONTH(TODAY), "99")   + "-" +
        STRING(DAY(TODAY),   "99")   + "T" +
        STRING(TIME, "HH:MM:SS").

    gcJson = gcLB
        /* ---------- collector ---------- */
        + gcQ + "collector" + gcQ + ":" + gcLB
        + gcQ + "name"         + gcQ + ":" + gcQ + {&COLLECTOR_NAME}    + gcQ + ","
        + gcQ + "version"      + gcQ + ":" + gcQ + {&COLLECTOR_VERSION} + gcQ + ","
        + gcQ + "language"     + gcQ + ":" + gcQ + {&COLLECTOR_LANG}    + gcQ + ","
        + gcQ + "generated_at" + gcQ + ":" + gcQ + cTimestamp           + gcQ + ","
        + gcQ + "status"       + gcQ + ":" + gcQ + gcCollectStat        + gcQ
        + gcRB + ","

        /* ---------- database ---------- */
        + gcQ + "database" + gcQ + ":" + gcLB
        + gcQ + "logical_name"       + gcQ + ":" + fnJsonStr(gcLogicalName)  + ","
        + gcQ + "physical_name"      + gcQ + ":" + fnJsonStr(gcPhysicalName) + ","
        + gcQ + "physical_path"      + gcQ + ":" + fnJsonStr(gcPhysicalPath) + ","
        + gcQ + "host"               + gcQ + ":" + fnJsonStr(gcHost)         + ","
        + gcQ + "openedge_version"   + gcQ + ":" + fnJsonStr(gcDbVersion)    + ","
        + gcQ + "db_status"          + gcQ + ":" + fnJsonStr(gcDbStatus)     + ","
        + gcQ + "pid"                + gcQ + ":" + fnJsonInt(giPid)          + ","
        + gcQ + "uptime_seconds"     + gcQ + ":" + fnJsonNum(gdUptimeSec)    + ","
        + gcQ + "active_connections" + gcQ + ":" + fnJsonInt(giActConnects)  + ","
        + gcQ + "notes" + gcQ + ":null"
        + gcRB + ","

        /* ---------- summary ---------- */
        + gcQ + "summary" + gcQ + ":" + gcLB
        + gcQ + "health_status" + gcQ + ":" + gcQ + gcHealthStat + gcQ + ","
        + gcQ + "error_count"   + gcQ + ":" + fnJsonInt(giErrorCount)   + ","
        + gcQ + "warning_count" + gcQ + ":" + fnJsonInt(giWarningCount)
        + gcRB + ","

        /* ---------- metrics ---------- */
        + gcQ + "metrics" + gcQ + ":" + gcLB
        + gcQ + "io"            + gcQ + ":" + gcLB + gcSecIO  + gcRB + ","
        + gcQ + "memory"        + gcQ + ":" + gcLB + gcSecMem + gcRB + ","
        + gcQ + "transactions"  + gcQ + ":" + gcLB + gcSecTrx + gcRB + ","
        + gcQ + "locks"         + gcQ + ":" + gcLB + gcSecLck + gcRB + ","
        + gcQ + "connections"   + gcQ + ":" + gcLB + gcSecCon + gcRB + ","
        + gcQ + "services"      + gcQ + ":" + gcLB + gcSecSvc + gcRB + ","
        + gcQ + "configuration" + gcQ + ":" + gcLB + gcSecCfg + gcRB + ","
        + gcQ + "license"       + gcQ + ":" + gcLB + gcSecLic + gcRB + ","
        + gcQ + "servers"       + gcQ + ":" + gcLB + gcSecSrv + gcRB + ","
        + gcQ + "storage"       + gcQ + ":" + gcLB + gcSecStg + gcRB + ","
        + gcQ + "backup"        + gcQ + ":" + gcLB + gcSecBkp + gcRB
        + gcRB + ","

        /* ---------- errors ---------- */
        + gcQ + "errors" + gcQ + ":[" + gcErrorsJson + "]"
        + gcRB.
END PROCEDURE.


/* ====================================================================
   BLOCO PRINCIPAL
   --------------------------------------------------------------------
   Ordem de execução:
     1) Identificação do banco (necessário primeiro: define uptime,
        dados básicos para o cabeçalho).
     2) Configuração (parseia DBPARAM e carrega -B, -L, -n etc. que
        são usados em cálculos de %).
     3) Coletas paralelas das demais categorias.
     4) Agregação de status.
     5) Montagem do JSON final.
     6) Emissão única em STDOUT.
   ==================================================================== */
MAIN-BLOCK:
DO ON ERROR UNDO, LEAVE:

    /* Inicializa caractere de aspas duplas para montagem JSON.
       Usa CHR(34) porque ~" (tilde-escape) não funciona de forma
       consistente em todos os compiladores OE 12.x. */
    ASSIGN
        gcQ  = CHR(34)
        gcLB = CHR(123)
        gcRB = CHR(125).

    /* Detecta modo debug via SESSION:PARAMETER.
       Uso: mpro ... -p openedgezbx.p -param "debug=true"
       Quando debug=true, cada métrica inclui unit, status,
       thresholds, source e observation. Caso contrário (padrão),
       retorna apenas "nome": valor — ideal para Zabbix. */
    IF INDEX(SESSION:PARAMETER, "debug=true") > 0 THEN
        glDebug = TRUE.

    /* 1) Identificação — também calcula uptime */
    RUN pCollectIdentification NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("identification",
                      "Falha geral na coleta de identificação: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectIdentification", "error").

    /* 2) Configuração — necessário antes de Memory/Connections */
    RUN pCollectConfiguration NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("configuration",
                      "Falha geral na coleta de configuração: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectConfiguration", "error").

    /* 3) Coletas das categorias */
    RUN pCollectIO NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("io",
                      "Falha na coleta de I/O: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectIO", "error").

    RUN pCollectMemory NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("memory",
                      "Falha na coleta de memória: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectMemory", "error").

    RUN pCollectTransactions NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("transactions",
                      "Falha na coleta de transações: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectTransactions", "error").

    RUN pCollectLocks NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("locks",
                      "Falha na coleta de locks: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectLocks", "error").

    RUN pCollectConnections NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("connections",
                      "Falha na coleta de conexões: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectConnections", "error").

    RUN pCollectServices NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("services",
                      "Falha na coleta de serviços: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectServices", "error").

    RUN pCollectStorage NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("storage",
                      "Falha na coleta de storage: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectStorage", "error").

    RUN pCollectBackup NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("backup",
                      "Falha na coleta de backup: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectBackup", "error").

    RUN pCollectServers NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("servers",
                      "Falha na coleta de servidores: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectServers", "error").

    RUN pCollectLicense NO-ERROR.
    IF ERROR-STATUS:ERROR THEN
        RUN pAddError("license",
                      "Falha na coleta de licenciamento: " + ERROR-STATUS:GET-MESSAGE(1),
                      "pCollectLicense", "error").

    /* 4) Agrega status global */
    RUN pBuildHealthSummary.

    /* 5) Monta o JSON final */
    RUN pBuildJson.

END.  /* MAIN-BLOCK */

/* 6) Emite o JSON via STDOUT (sem stream nomeado, sem arquivo)        */
/*    PUT UNFORMATTED não aceita LONGCHAR; usamos COPY-LOB para um     */
/*    MEMPTR e depois escrevemos byte a byte... Na verdade, o modo     */
/*    mais simples em OE 12.2 é converter para CHARACTER se couber     */
/*    (limite ~32K) ou usar COPY-LOB TO FILE com stdout.               */
/*    Abordagem segura: COPY-LOB gcJson TO FILE "/dev/stdout" no Linux */
/*    ou usar substring chunks em CHARACTER para PUT UNFORMATTED.      */
DEFINE VARIABLE cChunk  AS CHARACTER NO-UNDO.
DEFINE VARIABLE iLen    AS INT64     NO-UNDO.
DEFINE VARIABLE iOffset AS INT64     NO-UNDO INITIAL 1.
DEFINE VARIABLE iChunk  AS INTEGER   NO-UNDO INITIAL 30000.

iLen = LENGTH(gcJson).
DO WHILE iOffset <= iLen:
    cChunk = SUBSTRING(gcJson, iOffset, iChunk).
    PUT UNFORMATTED cChunk.
    iOffset = iOffset + iChunk.
END.
PUT UNFORMATTED SKIP.

/* Encerra explicitamente o programa */
QUIT.
