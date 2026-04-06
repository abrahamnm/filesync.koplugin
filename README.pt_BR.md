# FileSync - Gerenciador de Arquivos Sem Fio para KOReader

[English](README.md) | [Español](README.es.md) | **Português** | [中文](README.zh_CN.md) | [العربية](README.ar.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

Um plugin para KOReader que inicia um servidor web local no seu leitor eletrônico e exibe um código QR na tela. Escaneie o código com seu celular para abrir uma interface web completa que permite gerenciar livros e arquivos sem fio — sem cabos, sem aplicativos, apenas o seu navegador.

Funciona em dispositivos **Kindle** e **Kobo** com KOReader instalado.

<p align="center">
  <img src="screenshots/qr-screen.png" alt="Código QR na tela do leitor eletrônico" width="500">
</p>
<p align="center">
  <img src="screenshots/web-home.png" alt="Interface web - início" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Interface web - diretório" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Interface web - detalhes do arquivo" width="250">
</p>

## Funcionalidades

- **Acesso por QR** — Escaneie para conectar instantaneamente, sem digitar URLs
- **Explorador de Arquivos** — Navegue pela sua biblioteca com navegação por breadcrumbs
- **Upload de Arquivos** — Arraste e solte ou toque para enviar livros do seu celular
- **Download de Arquivos** — Salve qualquer arquivo no seu celular com um toque
- **Criar Pastas** — Organize sua biblioteca em diretórios
- **Renomear e Excluir** — Gerenciamento básico de arquivos com diálogos de confirmação
- **Busca e Ordenação** — Filtre por nome, ordene por nome/tamanho/data/tipo
- **Temas Claro e Escuro** — Detectados automaticamente ou alternados manualmente
- **Múltiplos Modos de Exibição** — Visualização em lista, grade e grade grande
- **Suporte a Vários Idiomas** — Disponível em 10 idiomas (inglês, espanhol, português, chinês, árabe, francês, alemão, russo, japonês, coreano)
- **Suporte a Layout RTL** — Layout completo da direita para a esquerda para árabe
- **Prevenção de Suspensão** — Mantém o dispositivo ativo e o WiFi conectado enquanto o servidor estiver em execução
- **Modo Seguro** — Exibe apenas livros e imagens, ocultando arquivos do sistema
- **Interface Responsiva** — Projetada para smartphones, funciona em qualquer tela

## Como Funciona

1. Conecte seu leitor eletrônico ao WiFi
2. Abra o plugin FileSync no menu Ferramentas de Rede do KOReader
3. Um código QR aparecerá na tela do leitor
4. Escaneie com seu celular (conectado à mesma rede WiFi)
5. Gerencie seus livros pela interface web no navegador do seu celular

## Instalação

### Pré-requisitos

- Um leitor eletrônico Kindle ou Kobo com [KOReader](https://github.com/koreader/koreader) instalado
- Seu leitor eletrônico e celular conectados à mesma rede WiFi

### Opção 1: Pelo arquivo de lançamento (Recomendado)

1. Baixe o arquivo `.zip` mais recente na página de [Lançamentos](../../releases)
2. Extraia o arquivo compactado
3. Copie a pasta `filesync.koplugin` para o diretório de plugins do KOReader no seu dispositivo (veja os caminhos acima)
4. Reinicie o KOReader

### Opção 2: Cópia direta

1. Conecte seu leitor eletrônico ao computador via USB

2. Localize o diretório de plugins do KOReader:
   - **Kindle:** `/mnt/us/koreader/plugins/`
   - **Kobo:** `.adds/koreader/plugins/` (na raiz do cartão SD)

3. Copie a pasta completa `filesync.koplugin` para o diretório de plugins:
   ```
   plugins/
   ├── filesync.koplugin/
   │   ├── _meta.lua
   │   ├── main.lua
   │   └── filesync/
   │       ├── filesyncmanager.lua
   │       ├── httpserver.lua
   │       ├── fileops.lua
   │       ├── filesync_i18n.lua
   │       ├── qrcode.lua
   │       ├── static/
   │       │   └── index.html
   │       └── i18n/
   │           ├── en.po
   │           ├── es.po
   │           ├── pt_BR.po
   │           ├── zh_CN.po
   │           ├── ar.po
   │           ├── fr.po
   │           └── ...
   ├── other.koplugin/
   └── ...
   ```

4. Ejete com segurança e reinicie o KOReader

### Verificando a instalação

Após reiniciar o KOReader, abra o menu superior e navegue até:

**Rede → FileSync**

Se a entrada aparecer no menu, o plugin está instalado corretamente.

## Uso

### Iniciando o servidor

0. Certifique-se de que seu dispositivo esteja conectado ao WiFi
1. Abra o menu superior do KOReader
2. Navegue até **Rede → FileSync**
3. Toque em **Iniciar servidor de arquivos**
4. Um código QR aparecerá na tela com a URL de conexão

<p align="center">
  <img src="screenshots/menu.png" alt="Menu do FileSync no KOReader" width="350">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/qr-screen.png" alt="Tela com código QR" width="350">
</p>

### Conectando pelo celular

1. Certifique-se de que seu celular esteja na **mesma rede WiFi** que o leitor eletrônico
2. Abra a câmera do celular e escaneie o código QR
3. Toque no link para abrir a interface web no navegador
4. Alternativamente, digite manualmente a URL exibida abaixo do código QR

### Gerenciando arquivos

Uma vez conectado, a interface web permite:

- **Navegar** — Toque nas pastas para explorar sua biblioteca. Use a barra de breadcrumbs no topo para voltar a qualquer diretório anterior.
- **Enviar** — Toque no botão **Upload** no cabeçalho, depois escolha arquivos ou arraste-os para a zona de upload. Vários arquivos podem ser enviados de uma vez.
- **Detalhes do arquivo** — Toque em qualquer arquivo para abrir sua visualização detalhada, onde você pode **baixar**, **renomear** ou **excluir**.
- **Criar pastas** — Toque no botão **Pasta** no cabeçalho e digite um nome.
- **Buscar** — Use a barra de busca para filtrar o diretório atual por nome de arquivo.
- **Ordenar** — Use o menu suspenso para ordenar por nome, data, tamanho ou tipo em ordem crescente ou decrescente.

<p align="center">
  <img src="screenshots/web-home.png" alt="Explorador de arquivos - início" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Explorador de arquivos - diretório com upload" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Visualização de detalhes do arquivo" width="250">
</p>

### Prevenção de suspensão

Enquanto o servidor de arquivos estiver em execução, o plugin impede automaticamente que o dispositivo entre em modo de suspensão. Isso mantém o servidor acessível e o WiFi conectado sem interrupções. Especificamente:

- Os modos de **espera** e **suspensão** são bloqueados para que o dispositivo permaneça ativo
- Os temporizadores de **suspensão automática** e **espera automática** são desativados temporariamente
- O **keepalive de WiFi** é ativado para manter a conexão de rede

Todas as configurações são restauradas aos valores anteriores quando o servidor é parado. Se o dispositivo entrar em suspensão por algum motivo (por exemplo, bateria criticamente baixa), o servidor será reiniciado automaticamente quando o dispositivo despertar.

### Parando o servidor

- Toque em **Parar servidor de arquivos** no menu do plugin, ou
- O servidor para automaticamente quando você fecha o KOReader

### Alterando a porta

1. Abra o menu do plugin
2. Toque em **Porta do servidor**
3. Digite um número de porta entre 1024 e 65535 (padrão: 8080)
4. Reinicie o servidor para que a alteração tenha efeito

### Modo Seguro

O modo seguro está **ativado por padrão** e limita a interface web para exibir apenas arquivos relevantes para sua biblioteca de leitura. Quando ativado:

- Apenas **e-books** (EPUB, PDF, MOBI, AZW3, FB2, DJVU, CBZ, etc.), **documentos** (TXT, DOC, RTF, HTML, etc.) e **imagens** (JPG, PNG, GIF, WebP) são exibidos
- Arquivos do sistema, arquivos de configuração e outros arquivos não relacionados a livros ficam ocultos
- Diretórios de metadados do KOReader (pastas `.sdr`) ficam ocultos e são limpos automaticamente ao excluir um livro

Para alternar o modo seguro, abra o menu do plugin e toque em **Modo seguro**. Desativá-lo mostrará todos os arquivos do dispositivo.

## Solução de problemas

**O plugin não aparece no menu**
- Certifique-se de que a pasta tenha exatamente o nome `filesync.koplugin` (diferencia maiúsculas e minúsculas)
- Verifique se `_meta.lua` e `main.lua` estão diretamente dentro da pasta (não em subpastas)
- Reinicie o KOReader completamente

**Erro "WiFi não está ativado"**
- Conecte seu leitor eletrônico a uma rede WiFi antes de iniciar o servidor
- Alguns dispositivos exigem que o WiFi seja ativado explicitamente nas configurações de rede do KOReader

**O celular não consegue conectar**
- Verifique se ambos os dispositivos estão na mesma rede WiFi
- Tente digitar a URL manualmente em vez de escanear o código QR
- Verifique se o roteador tem o isolamento de clientes ativado (impede que dispositivos se comuniquem entre si)
- No Kindle: o plugin gerencia as regras de firewall automaticamente, mas reiniciar pode ajudar se as regras estiverem travadas

**O upload falha**
- Verifique o espaço de armazenamento disponível no dispositivo
- Arquivos muito grandes podem causar timeout — tente enviar em lotes menores
- Certifique-se de que o diretório de destino tenha permissão de escrita

## Contribuindo

Contribuições são bem-vindas!

1. Faça um fork do repositório
2. Crie uma branch para sua funcionalidade
3. Faça suas alterações
4. Teste em um dispositivo real, se possível
5. Envie um pull request

## Licença

Este projeto está licenciado sob a [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html), em conformidade com o projeto KOReader.
