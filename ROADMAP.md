# Roadmap

Este arquivo existe para manter os PRs pequenos, ordenados e rastreaveis.
Atualize o status ao iniciar e ao finalizar cada PR.

## Como usar

- Mude o `Status` do PR para `in_progress`, `done`, `blocked` ou `impossible`.
- Ao terminar um PR, registre o resultado em `Concluido`.
- Se algo travar ou se mostrar inviavel, registre em `Dificil` ou `Impossivel`.
- Nao abra um PR grande pulando dependencias sem antes registrar a mudanca aqui.

## Legenda

- `planned`: ainda nao iniciado
- `in_progress`: em andamento
- `done`: concluido
- `blocked`: travado por dependencia ou decisao
- `impossible`: descartado por inviabilidade tecnica ou custo desproporcional

## Decisoes Pendentes

### DEC-01: Modelo do Root PIN

Status: `done`

Precisamos fechar uma decisao antes do PR de armazenamento do PIN:

- Opcao recomendada: remover `Reveal Root PIN` e armazenar apenas hash com salt.
- Opcao alternativa: manter `Reveal Root PIN`, aceitar o tradeoff de conveniencia e nao vender isso como seguranca forte.

Decisao tomada:

- Manter `Reveal Root PIN`.
- Manter o PIN em armazenamento local para permitir reveal no dispositivo.
- Documentar claramente que isso e conveniencia local, nao seguranca forte.

## Fila de PRs

| ID | Status | Prioridade | Titulo | Dependencias |
| --- | --- | --- | --- | --- |
| PR-01 | done | Alta | Sessao por cliente e token de autenticacao | nenhuma |
| PR-02 | done | Alta | Endurecimento do Root PIN | DEC-01 |
| PR-03 | done | Alta | Rate-limit real para unlock | PR-01 |
| PR-04 | planned | Alta | Limite de upload e protecao de memoria | nenhuma |
| PR-05 | done | Media | Firewall Kindle e cleanup mais confiaveis | nenhuma |
| PR-06 | done | Media | Higiene de produto e metadados | nenhuma |
| PR-07 | done | Media | Auto-restart apos reconexao WiFi | PR-05 |
| PR-08 | done | Baixa | Modularizacao de `fileops.lua` | PR-04, PR-06 |

## Escopo e Criterio de Aceite

### PR-01: Sessao por cliente e token de autenticacao

- Remover o conceito de `root_unlocked` global.
- Criar sessao ou token por cliente apos unlock.
- Exigir token valido nas rotas que dependem de Root mode.
- Implementar logout e expiracao de sessao.
- Revisar CORS para nao deixar `Access-Control-Allow-Origin: *` aberto sem necessidade.

### PR-02: Endurecimento do Root PIN

- Aplicar a decisao de `DEC-01`.
- Se a decisao for hash: armazenar hash com salt e migracao limpa do formato antigo.
- Se a decisao for manter reveal: documentar claramente que o PIN e conveniencia local, nao segredo forte.
- Garantir compatibilidade com a UI atual ou ajustar a UX conforme a decisao.

### PR-03: Rate-limit real para unlock

- Substituir o throttle atual por backoff progressivo.
- Preferir controle por sessao e, quando fizer sentido, por IP.
- Resetar tentativas com sucesso real de autenticacao.
- Expor erro claro para a UI com tempo de espera.

### PR-04: Limite de upload e protecao de memoria

- Definir tamanho maximo configuravel para upload.
- Validar `Content-Length` antes de ler o corpo inteiro quando possivel.
- Retornar erro claro quando o limite for excedido.
- Evitar que requests grandes derrubem a instancia por consumo de memoria.

### PR-05: Firewall Kindle e cleanup mais confiaveis

- Validar sucesso ou falha do `iptables`.
- Tentar path absoluto ou fallback seguro quando necessario.
- Melhorar logs para nao reportar sucesso falso.
- Garantir cleanup defensivo de firewall e standby em falhas de start/stop.

### PR-06: Higiene de produto e metadados

- Corrigir URL do About para o repositorio correto.
- Parar de hardcodar a versao em `main.lua`.
- Tornar `_meta.lua` a fonte unica da versao, se adotado.
- Remover `icon.bak.png` do controle de versao e adicionar regra de ignore.

### PR-07: Auto-restart apos reconexao WiFi

- Detectar perda e retorno da conectividade.
- Reiniciar o servidor apenas quando o estado anterior indicar que isso faz sentido.
- Evitar loops de restart.

### PR-08: Modularizacao de `fileops.lua`

- Separar o arquivo por dominio funcional.
- Preservar comportamento existente.
- Fazer isso somente depois dos PRs de risco mais alto.
- Idealmente entrar com testes basicos de upload, listagem e metadata antes ou junto.

## Fora de Escopo por Agora

- HTTPS com certificado self-signed antes de resolver sessao por cliente.
- Progresso de upload chunked antes de ter limite de upload.
- Refatoracao grande sem antes estabilizar seguranca e robustez.

## Registro de Execucao

### Concluido

- 2026-03-22 | PR-01 | Sessao Root por cliente com token em cookie HttpOnly, expiracao no servidor e invalidacao da UI ao expirar | Ainda sem teste funcional no Kindle neste ambiente
- 2026-03-22 | DEC-01 + PR-02 | `Reveal Root PIN` mantido, armazenamento do PIN alinhado a conveniencia local e limpeza de resquicios do modelo hash-only | Ainda sem teste funcional no Kindle neste ambiente
- 2026-03-22 | PR-03 | Rate-limit de unlock com backoff progressivo por cliente, `Retry-After` e reset apenas em autenticacao bem-sucedida | Ainda sem teste funcional no Kindle neste ambiente
- 2026-03-22 | PR-05 | `iptables` com fallback de path, logs de falha reais e cleanup defensivo de firewall e standby em start/stop | Ainda sem teste funcional no Kindle neste ambiente
- 2026-03-22 | PR-06 | About apontando para o repo correto, versao lida de `_meta.lua` e `icon.bak.png` removido com `.gitignore` no root | Ainda sem teste funcional no Kindle neste ambiente
- 2026-03-22 | PR-07 | Monitor leve de WiFi para parar ao perder conectividade e reiniciar silenciosamente ao reconectar ou trocar IP, preservando a intencao de restart | Ainda sem teste funcional no Kindle neste ambiente
- 2026-03-22 | PR-08 | `fileops.lua` dividido em bootstrap e modulos separados para browse, upload, metadata e operacoes de arquivo, preservando a API publica usada pelo servidor HTTP | PR-04 continua pendente para endurecimento do fluxo de upload
- 2026-03-22 | Hotfix | Start agora exige Root PIN antes do primeiro uso e faz fallback automatico de porta `80` para `8080` quando o bind falha na porta padrao sem configuracao manual | Portas escolhidas manualmente continuam sob controle do usuario

### Dificil

- 2026-03-22 | PR-01 | O ambiente nao tinha `lua`, `luajit` nem `luac` para validacao automatica da sintaxe Lua | Revisao manual do diff e validacao do JavaScript com `node`
- 2026-03-22 | PR-02 | Manter `Reveal Root PIN` impede endurecimento forte com hash irreversivel | Tradeoff de produto documentado no roadmap
- 2026-03-22 | PR-03 | O ambiente continua sem runtime Lua para exercitar o fluxo HTTP automatizado | Revisao manual da logica e `git diff --check`
- 2026-03-22 | PR-05 | O ambiente nao expõe um Kindle para validar os caminhos reais do `iptables` e o comportamento do firewall em runtime | Fallback para `/usr/sbin/iptables`, `/sbin/iptables` e `PATH`, com logs e cleanup defensivo
- 2026-03-22 | PR-07 | Nao havia um hook local claro de evento de reconexao WiFi visivel neste workspace | Polling leve com `UIManager:scheduleIn` e restart apenas em transicao de offline para online
- 2026-03-22 | PR-08 | O ambiente continua sem runtime Lua para exercitar o bootstrap modularizado por `dofile` e sem testes automatizados de smoke para `fileops` | Validacao estrutural por diff, referencias cruzadas e `git diff --check`
- 2026-03-22 | Hotfix | O Root PIN do plugin nao resolve a restricao de portas privilegiadas do sistema operacional | O fluxo passou a separar onboarding de PIN e fallback automatico apenas para a porta padrao

### Impossivel

- Nenhum item registrado ainda.

## Template para atualizar apos cada PR

Use este formato:

```md
### Concluido
- 2026-03-22 | PR-01 | Resumo curto do que entrou | Risco residual, se houver

### Dificil
- 2026-03-22 | PR-02 | O que dificultou | Decisao tomada para seguir

### Impossivel
- 2026-03-22 | PR-05 | O que nao foi possivel fazer | Alternativa adotada
```
