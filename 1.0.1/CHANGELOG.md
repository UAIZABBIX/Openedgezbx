# Changelog

Todos os marcos relevantes do projeto `openedgezbx`.

## [1.3.2] - 2026-04-14

### Adicionado — Portabilidade do .r, filtros globais, _DbParams, auditoria de configuracao

#### Portabilidade entre bancos via alias DICTDB
- Todas as 50 referencias de VST qualificadas com `DICTDB.<tabela>` (FIND FIRST, FOR EACH, AVAILABLE, WHERE)
- Adicionado `CREATE ALIAS DICTDB FOR DATABASE VALUE(LDBNAME(1)) NO-ERROR.` no MAIN-BLOCK
- O `.r` compilado agora e PORTATIL — pode ser executado contra qualquer banco
- **Resolve o erro `(1006) Database X not connected`** que aparecia ao mover o `.r` entre bancos
- Atencao: `DELETE ALIAS DICTDB NO-ERROR.` causa erro 247 no compilador OE 12.2 — usar apenas `CREATE ALIAS` (substitui automaticamente)

#### Filtros INCLUDE_DIRS/EXCLUDE_DIRS aplicados globalmente
- Nova funcao `db_passes_filters()` no shell collector
- Aplicada em 4 contextos:
  1. Coleta normal (executa o `.p` apenas em bancos que passam no filtro)
  2. Gravacao no inventario (so registra bancos filtrados)
  3. Processamento de bancos offline (so gera JSON offline para bancos filtrados)
  4. Limpeza de JSONs orfaos (le `physical_path` do proprio JSON e remove se nao passa filtro)
- Bug anterior corrigido: bancos no inventario antigo sem filtros continuavam gerando JSON offline mesmo apos configurar EXCLUDE
- Limpeza automatica de JSONs orfaos via leitura do `physical_path` do proprio JSON

#### Deteccao correta de brokers/servers BOTH/4GL/SQL
- `_Server-Type` no OE 12.2 so tem valores `"Login"`, `"Auto"`, `"Brokr"`, `"Inactive"` (NAO contem SQL/4GL)
- Tipo real esta nos arrays paralelos `_SrvParam-Name[]` e `_SrvParam-Value[]`
- Procurar indice onde `_SrvParam-Name = "-ServerType"` e ler `_SrvParam-Value`
- Valores possiveis: `"ABL"`, `"4GL"`, `"SQL"`, `"BOTH"` (BOTH aceita ambos)
- Servidores `"Inactive"` agora ignorados (eram contados antes)
- Brokers `BOTH` contabilizados em ambos 4GL e SQL

#### Novas metricas servers
- `brokers_4gl`, `brokers_sql`, `brokers_both` (count por tipo de aceitacao)
- `broker_ports` mostra ServerType real, ex: `"35000(BOTH/TCP)"`

#### HWM correto via `_AreaStatus` quando `_DbStatus-HiWater = 0`
- `_DbStatus-HiWater` reflete apenas a Schema Area, nao o banco todo
- Fallback: se `iHiWater = 0`, soma `_AreaStatus-Hiwater` de todas as areas
- Mesmo principio para `iFreeBlks` se a soma das areas for maior

#### `_DbParams` como fonte definitiva de parametros de startup
- `DBPARAM(1)` em ABL retorna apenas parametros do CLIENTE — `-B` aparecia como 0
- Substituido parsing de `DBPARAM` por leitura direta de `_DbParams` (143 entradas tipicas)
- Campos: `_DbParams-Name`, `_DbParams-Value`
- VST `_Startup` NAO existe no schema OE 12.2 do user (erro 725)
- Versao real do `.lg` capturada via `_DbParams` (nao mais via DBPARAM)

#### Renomeacao `-B1` -> `-B2` em todo o projeto
- `-B2` e o parametro alternativo correto (NAO `-B1`)
- Variaveis ABL: `giParamB1` -> `giParamB2`, `dBuf1AllocPct` -> `dBuf2AllocPct`, `dBuf1AllocGB` -> `dBuf2AllocGB`
- Chaves JSON: `pct_buffer_B1_alloc` -> `pct_buffer_B2_alloc`, `buffer_B1_alloc_gb` -> `buffer_B2_alloc_gb`, `startup_B1` -> `startup_B2`
- Templates Zabbix: `pct_buf_b1` -> `pct_buf_b2`, `buf_b1_gb` -> `buf_b2_gb`
- Nomes de graficos: "Buffer -B1" -> "Buffer -B2", "(-B vs -B1)" -> "(-B vs -B2)"

#### Novos items prototypes para parametros de startup (6 items)
- Startup -B, -B2, -L, -n, -spin, -bibufs
- Todos lidos de `metrics.configuration.startup_*`

#### Novos triggers de configuracao (7 triggers)
- 3 triggers de threshold: -B, -L, -spin abaixo do recomendado
- 4 triggers de auditoria via `change()`: -B, -L, -n, -spin alterados (qualquer mudanca entre coletas)
- Novas macros: `{$OZBX_STARTUP_B_MIN}=5000`, `{$OZBX_STARTUP_L_MIN}=8192`, `{$OZBX_STARTUP_SPIN_MIN}=5000`

#### Novos graficos prototypes (3 graficos)
- "Brokers by Type (4GL/SQL/BOTH)" — stacked
- "Startup Parameters (-B / -B2)"
- "Startup Parameters (-L / -n)"

#### JSON offline completo
- Funcao `gen_offline_json()` no shell collector com 90+ chaves
- Garante que todas as chaves esperadas pelo template existam mesmo quando banco offline
- Evita erro JSONPath "no data matches the specified path"

### Servidor de producao
- `brzmgrdbmstotvs01` (Linux) substituiu `openedgerdbms001` como servidor principal de teste
- Banco producao: `/producao/bancos/emsfnd`
- Bancos descobertos pelo `dbipcs` em ambientes filtrados (dev/homol/teste)

### VSTs novas utilizadas
- `_DbParams` — parametros de startup do servidor (143 entradas)

### Totais finais dos templates
- **113 item prototypes** por banco (era 107 na v1.3.1)
- **37 graph prototypes** por banco (era 35 na v1.3.1)
- **26 trigger prototypes** por banco (era 19 na v1.3.1)
- **20+ macros** configuraveis

### Alterado
- Bump de versao para 1.3.2

## [1.3.1] - 2026-04-14

### Adicionado — Inventario offline para deteccao automatica de bancos down

#### Sistema de inventario offline (`openedgezbx_collector.sh`)
- Novo arquivo `.openedgezbx_inventory` no diretorio do script rastreia todos os bancos ja vistos
- Quando um banco desaparece do `proutil -C dbipcs` (offline), o collector detecta via comparacao inventario vs dbipcs atual
- Gera JSON minimo com `database_online: false` e `db_status: "offline"` para bancos ausentes
- JSON offline inclui todas as secoes de metricas com valores 0/false (evita erro JSONPath no Zabbix)
- Quando o banco volta, a coleta normal sobrescreve o JSON e o trigger resolve automaticamente

#### Fluxo de deteccao offline
1. 1a execucao: dbipcs encontra bancos -> salva no inventario -> coleta normal
2. Banco cai: dbipcs nao encontra -> inventario lembra -> gera JSON offline
3. Banco volta: dbipcs encontra -> coleta normal -> trigger resolve

### Corrigido
- `fnJsonNum`: zero a esquerda para decimais < 1 (`.02` -> `0.02`, `-.02` -> `-0.02`)
- Storage: todos os calculos retornam 0 em vez de null para evitar erro JSONPath no Zabbix
- `_Database-Feature` confirmada como VST definitiva para features (substituiu heuristica falha `_MstrBlk-integrity`)
- Trigger "Database OFFLINE" mantido como severidade DISASTER (nao HIGH)

### VSTs validadas nesta sessao
- `_Database-Feature`: `_DBFeature-ID`, `_DBFeature_Name`, `_DBFeature_Active`, `_DBFeature_Enabled`
- `_AreaExtent`: `_Area-number`, `_Extent-number`, `_Extent-size`, `_Extent-type`, `_Extent-attrib`
- `_DbStatus` campos adicionais: `DbBlkSize`, `HiWater`, `FreeBlks`, `EmptyBlks`, `TotalBlks`, `RMFreeBlks`, `BiSize`, `fbDate`, `ibDate`, `ibSeq`, `NumAreas`, `NumLocks`, `MostLocks`

### Totais finais dos templates
- **104 item prototypes** por banco
- **34 graph prototypes** por banco
- **19 trigger prototypes** por banco (Database OFFLINE = DISASTER)
- **20+ macros** configuraveis

## [1.3.0] - 2026-04-12

### Adicionado — Storage, backup, servers, database features, areas/extents

#### Nova secao `metrics.storage` (procedure `pCollectStorage`)
- Usa `_DbStatus` campos: `DbBlkSize`, `HiWater`, `FreeBlks`, `EmptyBlks`, `TotalBlks`, `RMFreeBlks`, `NumAreas`, `NumLocks`, `MostLocks`, `BiSize`
- Calculos implementados:
  - Blocos em uso = HiWater - FreeBlks
  - Tamanho total DB em GB = TotalBlks * DbBlkSize / 1024^3
  - Tamanho usado em GB = (HiWater - FreeBlks) * DbBlkSize / 1024^3
  - Espaco livre reutilizavel em GB = FreeBlks * DbBlkSize / 1024^3
  - Espaco nao formatado em GB = EmptyBlks * DbBlkSize / 1024^3
  - % livre reutilizavel = (FreeBlks / HiWater) * 100
  - % consumido ate HWM = ((HiWater - FreeBlks) / HiWater) * 100
  - % buffer -B alocado = (-B / TotalBlks) * 100
  - % buffer -B1 alocado = (-B1 / TotalBlks) * 100
  - Memoria -B em GB = (-B * DbBlkSize) / 1024^3
  - Memoria -B1 em GB = (-B1 * DbBlkSize) / 1024^3
- **Todos os calculos protegidos:** retornam 0 em vez de null para evitar erro JSONPath no Zabbix

#### Database Features via `_Database-Feature`
- Removida heuristica falha via `_MstrBlk-integrity` bit 1
- Usa `_Database-Feature` com `_DBFeature_Active = "1"`
- 9 features monitoradas: Large Files (ID 5), 64-bit DBKEYS (9), Large Keys (10), 64-bit Sequences (11), Encryption (13), Auditing (6), Replication (1), Multi-tenancy (14), CDC (27)
- Metricas em `metrics.storage`

#### Monitoramento de areas/extents
- Para cada area (> area 6), encontra o ultimo `_AreaExtent`
- Classifica ultimo extent: fixo (type=37) ou variavel (type=5/4)
- Se < 5% livre no ultimo extent, marca como "at risk"
- Metricas: `areas_at_risk_count`, `areas_at_risk_names`, `areas_with_fixed_last_extent`, `areas_with_variable_last_extent`

#### Nova secao `metrics.backup` (monitoramento de backup)
- Campos: `_DbStatus-fbDate`, `_DbStatus-ibDate`, `_DbStatus-ibSeq`
- Nova funcao `fnParseCtime`: converte data ctime C ("Sat Oct 28 20:24:16 2023") para DATETIME
- Metricas: `minutes_since_full_backup`, `minutes_since_incr_backup`, `minutes_since_any_backup`, `last_backup_type`

#### Nova secao `metrics.servers` (brokers e servidores)
- `_Servers` — contagem por tipo (4GL vs SQL), brokers, portas, current/max users, logins, pending
- `_ActServer` — atividade: bytes/mensagens/records sent/received, queries
- Classificacao: `INDEX(_Server-Type, "SQL") > 0` para SQL, resto = 4GL

#### Parsing de -B1
- `giParamB1` adicionado ao parsing de DBPARAM

#### Banco offline — JSON minimo
- `openedgezbx_collector.sh` gera JSON com `database_online=false` quando mpro falha

#### Templates Zabbix atualizados
- **104 item prototypes** por banco (eram 58)
- **34 graph prototypes** por banco (eram 20)
- **19 trigger prototypes** por banco (eram 9)
- Novas macros: `{$OZBX_CONSUMED_HWM_WARN}=90`, `{$OZBX_CONSUMED_HWM_CRIT}=95`, `{$OZBX_FREE_REUSE_WARN}=10`, `{$OZBX_FREE_REUSE_CRIT}=5`, `{$OZBX_BACKUP_FULL_WARN}=1440`, `{$OZBX_BACKUP_FULL_CRIT}=2880`, `{$OZBX_BACKUP_ANY_WARN}=1440`, `{$OZBX_BACKUP_ANY_CRIT}=2880`

### Corrigido
- `fnJsonNum`: zero a esquerda para decimais < 1 (`.02` -> `0.02`)
- `pCollectStorage`: todos os calculos retornam 0 em vez de null para evitar erro JSONPath no Zabbix
- `_Database-Feature` em vez de `_MstrBlk-integrity` para large files check
- `mpro` em vez de `_progres` no collector
- `proutil -C dbipcs | grep Yes | awk '{print $NF}'` para ultimo campo

### Alterado
- Bump de versao para 1.3.0

### VSTs novas utilizadas
- `_Database-Feature` — features do banco (Large Files, 64-bit DBKEYS, Encryption, etc.)
- `_Servers` — brokers e servidores
- `_ActServer` — atividade de servidores
- `_AreaExtent` — extents por area

### VSTs descobertas (nao implementadas)
- `_DbServiceManagerObjects` — servicos (descoberto, nao implementado ainda)

## [1.2.0] - 2026-04-12

### Adicionado — Licenciamento, processos de servico e log file size

#### Nova secao `metrics.license` (procedure `pCollectLicense`)
- Usa VST `_License` com campos validados: `_Lic-ActiveConns`, `_Lic-BatchConns`, `_Lic-CurrConns`, `_Lic-MaxActive`, `_Lic-MaxBatch`, `_Lic-MaxCurrent`, `_Lic-MinActive`, `_Lic-MinBatch`, `_Lic-MinCurrent`, `_Lic-ValidUsers`
- Metricas: `lic_valid_users`, `lic_current_connections`, `lic_active_connections`, `lic_batch_connections`, `lic_usage_percent` (= `_Lic-CurrConns / _Lic-ValidUsers * 100`), `lic_max_active`, `lic_max_batch`, `lic_max_current`

#### Processos de servico (BIW, AIW, WDOG, APW)
- Detectados via `_Connect-Type` no loop existente de `pCollectConnections`
- Tipos monitorados: `"BIW"` (BI Writer), `"AIW"` (AI Writer), `"WDOG"` (Watchdog), `"APW"` (Async Page Writer)
- Metricas: `biw_process`, `aiw_process`, `wdog_process`, `apw_process` (count) em `metrics.connections`

#### Tamanho do arquivo .lg (log do banco)
- Implementado via `FILE-INFO:FILE-SIZE` no caminho `PDBNAME(1) + ".lg"`
- Metricas: `log_file_size_mb` (decimal, MB), `log_file_size_bytes` (int64, bytes) em `metrics.io`

#### Templates Zabbix atualizados
- **58 item prototypes** por banco (eram 49)
- **20 graph prototypes** por banco (eram 16)
- **9 trigger prototypes** (sem alteracao)
- Novos items: Licensed Users, License Current, License Usage %, License Max Current (peak), BIW/AIW/WDOG/APW Process, Log File Size MB
- Novos graficos: License Usage (Current vs Licensed), License Usage (%), Service Processes (BIW/AIW/WDOG/APW stacked), Log File Size (MB)

#### VSTs adicionais descobertas (para implementacao futura)
- `_Servers` — brokers/servidores com tipo, PID, porta, usuarios
- `_DbServiceManager` / `_DbServiceManagerObjects` — servicos com nome, status, ready
- `_Repl-Server`, `_Repl-Agent`, `_Repl-AgentActivity` — replicacao OpenEdge

### Alterado
- Bump de versao para 1.2.0

## [1.1.1] - 2026-04-12

### Corrigido — Formatacao numerica e templates Zabbix

#### fnJsonNum — zero a esquerda em decimais < 1
- `STRING(0.02)` retornava `".02"` (JSON invalido) — corrigido com `BEGINS "."` -> prepend `"0"`
- `STRING(-0.02)` retornava `"-.02"` (JSON invalido) — corrigido com `BEGINS "-."` -> prepend `"-0"` + `SUBSTRING(cVal, 2)`

#### Templates Zabbix 7.0
- `sortorder` em graph_items corrigido para string (`'1'`) em vez de inteiro
- Discovery `vfs.dir.get` corrigido para usar regex (`\.json$`) em vez de glob
- LLD macro corrigida para `{#PATHNAME}` (campo real do `vfs.dir.get`)
- Adicionado `DenyKey=system.run[*]` obrigatorio no `openedgezbx.conf`
- UUIDs validados como UUIDv4 (32 hex chars)
- `template_groups` em vez de `groups` (requisito Zabbix 7.0)

#### Documentacao
- README.md reescrito com documentacao completa do sistema (coletor + shell collector + templates + agent2)
- AGENT2_SETUP.md atualizado com DenyKey obrigatorio e particularidades da 7.0
- Adicionada tabela de referencia de _Resrc-Name na documentacao

## [1.1.0] - 2026-04-12

### Corrigido — Validacao em producao contra OE 12.8 (emsfnd/TSMART0001)

#### Nomes de _Resrc-Name
- `"Record Locks"` -> corrigido para `"Record Lock"` (sem 's') — nome real no OE 12.8
- `"Buffers"` -> corrigido para `"DB Buf Avail"` — nao existe entrada generica "Buffers"; buffers sao divididos em "DB Buf Read", "DB Buf Write", "DB Buf Avail" etc.

#### DBPARAM em conexao remota
- `fnExtractParam` corrigido para normalizar virgula->espaco antes do parsing — `DBPARAM(1)` retorna parametros separados por virgula (nao espaco) em conexoes remotas TCP

#### Protecao de tipos
- Adicionado `INT64(?)` como protecao em campos de `_AreaStatus` para evitar overflow em bancos grandes

#### Limpeza
- Removidas metricas de debug que poluiam a saida JSON

### Adicionado
- `openedgezbx_collector.sh` — script shell de coleta automatizada com setup interativo
- `openedgezbx_collector.env` — arquivo de configuracao gerado pelo setup
- `zabbix_templates/openedgezbx_passive.yaml` — template Zabbix 7.0 passivo com autodiscovery
- `zabbix_templates/openedgezbx_active.yaml` — template Zabbix 7.0 ativo
- `zabbix_templates/openedgezbx.conf` — configuracao do Zabbix Agent2
- `AGENT2_SETUP.md` — guia de configuracao do Agent2
- Modo debug via `-param "debug=true"`
- 11 graph prototypes autodescobertos por banco
- 9 trigger prototypes com severidades configuraveis
- 30 item prototypes (dependent items com JSONPath)
- Filtros INCLUDE_DIRS / EXCLUDE_DIRS no shell collector

### Alterado
- Bump de versao para 1.1.0

### Notas tecnicas
- Programa executado com sucesso em producao contra banco `emsfnd` em servidor `openedgerdbms001` (Linux, OE 12.2/12.8)
- JSON valido, 0 erros, todas as metricas com valores reais
- Metricas validadas: buffer_hit_ratio (98.8%), hi_water_total_blocks (771951), free_blocks (57), lock_table_current (956), active_record_locks (956), areas_count (8), active_connections (3), bi_cluster_avg_size_kb (1024), db_block_size (8192), database_online (true)
- Conexao remota nao traz `-B`, `-L`, `-n` (sao parametros server-side); metricas dependentes ficam `null` automaticamente
- Lista completa dos 27 registros `_Resrc-Name` documentada
- Templates Zabbix testados contra Zabbix 7.0.25

## [1.0.1] - 2026-04-12

### Corrigido — Erros de compilacao contra banco real OE 12.2 (emsfnd)

#### Campos VST inexistentes ou com grafia incorreta
- `_Buffer-Checkpoints` -> corrigido para `_Buffer-Chkpts` (campo real em `_ActBuffer`)
- `_BiLog-BytesWriten` -> corrigido para `_BiLog-BytesWrtn` (grafia truncada do OE 12.2)
- `_AiLog-BytesWriten` -> corrigido para `_AiLog-BytesWritn` (grafia truncada do OE 12.2)
- `_Summary-Commit` -> corrigido para `_Summary-Commits` (com 's')
- `_Summary-Undo` -> corrigido para `_Summary-Undos` (com 's')
- `_Summary-Trans` -> corrigido para `_Summary-TransComm` (campo real em `_ActSummary`)
- `_Lock-Wait` -> substituido pela soma `_Lock-ExclWait + _Lock-ShrWait + _Lock-UpgWait + _Lock-RecGetWait` (campo unitario nao existe em `_ActLock`)
- `_AreaStatus-Emptynum` -> removido (campo nao existe no schema OE 12.2)
- `_Resrc-Hwm` -> removido (`_Resrc` possui apenas: `_Resrc-Id`, `_Resrc-lock`, `_Resrc-Name`, `_Resrc-time`, `_Resrc-wait`)

#### Sintaxe ABL incompativel com o preprocessador/compilador OE 12.2
- Aspas simples `'...'` substituidas por aspas duplas `"..."` em todo o codigo (erro 293)
- Escape `~"` (tilde-quote) substituido por `CHR(34)` via variavel global `gcQ` (erro 293)
- Chaves `{` e `}` em strings literais substituidas por `CHR(123)` e `CHR(125)` via variaveis `gcLB`/`gcRB` (erro 496 — preprocessador interpretava como diretivas de include)
- `PUT UNFORMATTED` com `LONGCHAR` substituido por fatiamento em chunks `CHARACTER` de 30K via `SUBSTRING` (erro 11382)

#### Uptime
- Adotado `_Summary-UpTime` (INTEGER, segundos) como fonte primaria de uptime em vez de calculo manual a partir de `_DbStatus-StartTime`

### Adicionado
- Arquivo `emsfnd.pf` — parametros de conexao TCP para banco de teste (`192.168.0.124:35000`)

### Notas tecnicas
- Programa compilado com sucesso contra banco `emsfnd` em `192.168.0.124:35000` via TCP no Progress OpenEdge 12.2
- Todas as correcoes de campos VST foram validadas contra o schema real do banco

## [1.0.0] - 2026-04-11

### Adicionado
- Versao inicial do coletor `openedgezbx.p`.
- Sete categorias de metricas: `io`, `memory`, `transactions`, `locks`, `connections`, `services`, `configuration`.
- Estrutura JSON canonica com `collector`, `database`, `summary`, `metrics`, `errors`.
- Funcoes auxiliares: `fnEscape`, `fnJsonStr`, `fnJsonNum`, `fnJsonInt`, `fnMetric`, `fnClassHigh`, `fnClassLow`, `fnExtractParam`, `fnDivSafe`, `fnRound2`.
- Procedures de coleta: `pCollectIdentification`, `pCollectIO`, `pCollectMemory`, `pCollectTransactions`, `pCollectLocks`, `pCollectConnections`, `pCollectServices`, `pCollectConfiguration`.
- Tratamento de erro resiliente por bloco (`DO ON ERROR UNDO, LEAVE` + `NO-ERROR`).
- Saida exclusiva por STDOUT via `PUT UNFORMATTED`.
- Descoberta dinamica do banco via `LDBNAME(1)` / `PDBNAME(1)`.
- Parsing de parametros de startup (`-B`, `-L`, `-n`, `-spin`, `-bibufs`) a partir de `DBPARAM(1)`.
- Documentacao `README.md` com integracao Zabbix e mapeamento de VSTs.

### Notas tecnicas
- `_MyConnection` nao e usado: retornou erro `(725) Unknown or ambiguous table` na compilacao no ambiente alvo. Campo `pid` fica como `0`.
- `_MstrBlk-dbvers` e a versao do banco e nao foi confundido com block size; `db_block_size` vem de `_Area-blocksize`.
