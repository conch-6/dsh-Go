// 整页画布 (docs/design/roleplay-ui.md §3, roleplay-compat.md §6.3; the
// roadmap's level 2): the whole story in one web page, its DOM built the way
// SillyTavern builds it (#chat > .mes[mesid] > .mes_block > .mes_text), so a
// card's CSS that reaches across messages (#chat .mes …) takes, and ST's own
// colour variables (--SmartThemeQuoteColor …) carry the story's colours.
// Messages arrive as JSON through our script; the page itself is loaded once.
// Card scripts don't run yet: they come with the helper bridge. Component
// tags (<dsh-letter>…, roleplay-ui §5) are Web Components here, with parts
// and --dsh-* variables a card's CSS may restyle.

import 'dart:convert';
import 'dart:ui' show Color;

/// One message on the canvas.
final class TavernCanvasEntry {
  const TavernCanvasEntry({
    required this.mesid,
    required this.nodeId,
    required this.name,
    required this.html,
    this.isUser = false,
    this.isSystem = false,
  });

  /// Its place in the shown path, as ST numbers messages.
  final int mesid;
  final String nodeId;
  final String name;
  final String html;
  final bool isUser;
  final bool isSystem;

  Map<String, Object?> toJson() => {
    'mesid': mesid,
    'node': nodeId,
    'name': name,
    'html': html,
    'user': isUser,
    'system': isSystem,
  };
}

/// The words the canvas's components say, in the reader's language:
/// letterFrom and phoneFrom carry `{from}`, rollCheck `{skill}`.
final class TavernCanvasLabels {
  const TavernCanvasLabels({
    this.letter = 'A letter',
    this.letterFrom = 'A letter from {from}',
    this.taken = 'Got',
    this.clue = 'Clue',
    this.phone = 'A message',
    this.phoneFrom = 'Message from {from}',
    this.roll = 'Roll',
    this.rollCheck = 'Check: {skill}',
    this.success = 'Success',
    this.failure = 'Failure',
    this.game = "A mini-game goes here; it can't be played here yet",
  });

  final String letter, letterFrom, taken, clue, phone, phoneFrom, roll, rollCheck, success, failure, game;

  Map<String, String> toJson() => {
    'letter': letter,
    'letterFrom': letterFrom,
    'taken': taken,
    'clue': clue,
    'phone': phone,
    'phoneFrom': phoneFrom,
    'roll': roll,
    'rollCheck': rollCheck,
    'success': success,
    'failure': failure,
    'game': game,
  };
}

/// [entries] as our script's render() takes them.
String tavernCanvasJson(List<TavernCanvasEntry> entries) => jsonEncode([for (final e in entries) e.toJson()]);

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

final _tagOrText = RegExp(r'<[^<>]*>|[^<]+|<');

/// What is said, as ST marks it: the quote marks kept, inside a <q>.
final _said = RegExp('"[^"\\n]*"|\u201C[^\u201D\\n]*\u201D|\u00AB[^\u00BB\\n]*\u00BB|「[^」\\n]*」|『[^』\\n]*』|＂[^＂\\n]*＂');
final _strong = RegExp(r'\*\*(?!\s)([^*\n]+?)(?<!\s)\*\*');
final _em = RegExp(r'(?<![*\w])\*(?![\s*])([^*\n]+?)(?<!\s)\*(?![*\w])');
final _emUnderscore = RegExp(r'(?<![\w_])_(?![\s_])([^_\n]+?)(?<!\s)_(?![\w_])');
final _code = RegExp(r'`([^`\n]+)`');

/// Markdown's inline marks in [text], leaving HTML tags (and what their
/// attributes say) as written.
String _inline(String text) {
  final out = StringBuffer();
  for (final m in _tagOrText.allMatches(text)) {
    final piece = m[0]!;
    if (piece.startsWith('<') && piece.length > 1) {
      out.write(piece);
      continue;
    }
    // Code first: nothing inside it is formatted.
    var at = 0;
    for (final c in _code.allMatches(piece)) {
      out.write(_words(piece.substring(at, c.start)));
      out.write('<code>${_escape(c[1]!)}</code>');
      at = c.end;
    }
    out.write(_words(piece.substring(at)));
  }
  return out.toString();
}

String _words(String text) => text
    .replaceAllMapped(_strong, (m) => '<strong>${m[1]}</strong>')
    .replaceAllMapped(_em, (m) => '<em>${m[1]}</em>')
    .replaceAllMapped(_emUnderscore, (m) => '<em>${m[1]}</em>')
    .replaceAllMapped(_said, (m) => '<q>${m[0]}</q>');

final _fence = RegExp(r'^(`{3,}|~{3,})[ \t]*([\w-]*)[^\n]*\n([\s\S]*?)\n?^\1[ \t]*$', multiLine: true);
final _blockTag = RegExp(
  r'^<(div|p|style|script|table|details|section|article|center|ul|ol|blockquote|pre|h[1-6]|hr|img|svg|iframe|form|figure|dsh-[a-z-]+)\b',
  caseSensitive: false,
);
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');

/// A message's text as the canvas shows it: paragraphs with their line
/// breaks, Markdown's emphasis, what is said in <q>, ```html blocks and block
/// HTML as written, other code blocks escaped.
String tavernStoryHtml(String text) {
  final source = text.replaceAll('\r\n', '\n');
  final out = <String>[];
  void prose(String segment) {
    for (final block in segment.split(RegExp(r'\n[ \t]*\n'))) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;
      if (_blockTag.hasMatch(trimmed)) {
        out.add(trimmed);
      } else if (_heading.firstMatch(trimmed) case final h? when !trimmed.contains('\n')) {
        final level = h[1]!.length;
        out.add('<h$level>${_inline(h[2]!)}</h$level>');
      } else if (trimmed.split('\n').every((l) => l.trimLeft().startsWith('>'))) {
        final inner = [for (final l in trimmed.split('\n')) l.trimLeft().substring(1).trimLeft()].join('\n');
        out.add('<blockquote><p>${_inline(inner).replaceAll('\n', '<br>')}</p></blockquote>');
      } else {
        out.add('<p>${_inline(trimmed).replaceAll('\n', '<br>')}</p>');
      }
    }
  }

  var at = 0;
  for (final f in _fence.allMatches(source)) {
    prose(source.substring(at, f.start));
    final lang = f[2]!.toLowerCase();
    final body = f[3]!;
    out.add(
      lang == 'html'
          ? body
          : '<pre><code${lang.isEmpty ? '' : ' class="language-$lang"'}>${_escape(body)}</code></pre>',
    );
    at = f.end;
  }
  prose(source.substring(at));
  return out.join('\n');
}

String _css(Color c) =>
    'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(3)})';

/// The page the canvas loads once: ST's structure and colour variables, the
/// story's size and colours, and our script (allowed by [nonce]) that draws
/// what render()/stream() hand it and reports a long press on a message to
/// the `DshTavern` channel. [noScripts] and [offline] are 酒馆设置 › 安全's
/// choices, as for islands.
String tavernCanvasDocument({
  required Color text,
  required Color accent,
  required Color muted,
  required Color quote,
  required Color emphasis,
  required Color userTint,
  required double fontSize,
  required double lineHeight,
  required String nonce,
  String userLabel = '',
  TavernCanvasLabels labels = const TavernCanvasLabels(),
  bool noScripts = false,
  bool offline = false,
}) {
  final policy = noScripts || offline
      ? [
          if (offline) "default-src 'none'",
          if (offline) 'img-src data: blob:',
          if (offline) 'media-src data: blob:',
          if (offline) 'font-src data:',
          if (offline) "style-src 'unsafe-inline' data:",
          if (noScripts) "script-src 'nonce-$nonce'" else "script-src 'unsafe-inline' 'unsafe-eval' 'nonce-$nonce'",
          if (noScripts) "script-src-attr 'none'",
        ].join('; ')
      : null;
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${policy == null ? '' : '<meta http-equiv="Content-Security-Policy" content="$policy">'}
<style>
:root{
  --dsh-text:${_css(text)};--dsh-accent:${_css(accent)};--dsh-muted:${_css(muted)};--dsh-user:${_css(userTint)};
  --SmartThemeBodyColor:var(--dsh-text);--SmartThemeQuoteColor:${_css(quote)};--SmartThemeEmColor:${_css(emphasis)};
  --SmartThemeUnderlineColor:var(--dsh-accent);--SmartThemeBorderColor:var(--dsh-muted);
  --mainFontSize:${fontSize}px;
}
html,body{margin:0;padding:0;background:transparent;}
body{color:var(--dsh-text);font:var(--mainFontSize)/$lineHeight system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;overflow-wrap:anywhere;-webkit-text-size-adjust:100%;}
#chat{display:flex;flex-direction:column;gap:14px;padding:12px 16px 24px;}
.mes{display:flex;flex-direction:column;}
.mes .ch_name{font-size:.82em;font-weight:600;color:var(--dsh-accent);margin-bottom:2px;}
.mes[is_user="true"] .ch_name{color:var(--dsh-muted);}
.mes[is_user="true"] .mes_text{background:var(--dsh-user);border-radius:16px;padding:8px 12px;align-self:flex-end;max-width:85%;box-sizing:border-box;}
.mes[is_user="true"] .mes_block{align-items:flex-end;}
.mes[is_system="true"] .mes_text{color:var(--dsh-muted);font-style:italic;}
.mes_block{display:flex;flex-direction:column;}
.mes_text p{margin:0 0 .6em;}
.mes_text p:last-child{margin-bottom:0;}
.mes_text q{color:var(--SmartThemeQuoteColor);quotes:none;}
.mes_text q::before,.mes_text q::after{content:none;}
.mes_text em{color:var(--SmartThemeEmColor);}
.mes_text a{color:var(--dsh-accent);}
.mes_text img,.mes_text video,.mes_text svg{max-width:100%;height:auto;}
.mes_text pre{white-space:pre-wrap;}
.mes[data-streaming] .mes_text>:last-child::after,.mes[data-streaming] .mes_text:empty::after{content:"\\25CF";color:var(--dsh-muted);margin-left:3px;font-size:.6em;vertical-align:middle;}
</style></head>
<body><div id="chat"></div>
<script nonce="$nonce">
(function(){
  var chat=document.getElementById('chat');
  var userLabel=${jsonEncode(userLabel)};
  function nearBottom(){return window.innerHeight+window.scrollY>=document.body.scrollHeight-80;}
  function toBottom(){window.scrollTo(0,document.body.scrollHeight);}
  function mes(e){
    var m=document.createElement('div');
    m.className='mes';
    m.setAttribute('mesid',String(e.mesid));
    m.setAttribute('ch_name',e.name||'');
    m.setAttribute('is_user',e.user?'true':'false');
    m.setAttribute('is_system',e.system?'true':'false');
    m.dataset.node=e.node||'';
    var block=document.createElement('div');block.className='mes_block';
    var name=document.createElement('div');name.className='ch_name';
    var nameText=document.createElement('span');nameText.className='name_text';
    nameText.textContent=e.user?(userLabel||e.name||''):(e.name||'');
    name.appendChild(nameText);
    var text=document.createElement('div');text.className='mes_text';
    text.innerHTML=e.html||'';
    block.appendChild(name);block.appendChild(text);m.appendChild(block);
    return m;
  }
  var stream=null;
  window.dsh={
    render:function(list){
      var stay=nearBottom()||!chat.firstChild;
      chat.textContent='';stream=null;
      for(var i=0;i<list.length;i++){chat.appendChild(mes(list[i]));}
      if(stay)toBottom();
    },
    stream:function(name,html){
      var stay=nearBottom();
      if(html===null){if(stream){stream.remove();stream=null;}return;}
      if(!stream){stream=mes({mesid:chat.children.length,node:'',name:name,html:'',user:false,system:false});stream.dataset.streaming='1';chat.appendChild(stream);}
      stream.querySelector('.mes_text').innerHTML=html;
      if(stay)toBottom();
    }
  };
  var hold=null,from=null;
  function post(o){if(window.DshTavern)DshTavern.postMessage(JSON.stringify(o));}
  function owner(t){while(t&&t!==chat){if(t.classList&&t.classList.contains('mes'))return t;t=t.parentNode;}return null;}
  chat.addEventListener('touchstart',function(ev){
    var m=owner(ev.target);if(!m||!m.dataset.node)return;
    from=ev.touches[0];
    hold=setTimeout(function(){hold=null;post({type:'menu',node:m.dataset.node});},550);
  },{passive:true});
  function cancel(){if(hold){clearTimeout(hold);hold=null;}}
  chat.addEventListener('touchmove',function(ev){
    if(!from||!hold)return;var t=ev.touches[0];
    if(Math.abs(t.clientX-from.clientX)+Math.abs(t.clientY-from.clientY)>10)cancel();
  },{passive:true});
  chat.addEventListener('touchend',cancel);
  chat.addEventListener('touchcancel',cancel);
  chat.addEventListener('contextmenu',function(ev){
    var m=owner(ev.target);if(!m||!m.dataset.node)return;
    if(String(window.getSelection())==='')ev.preventDefault();
  });
  // Component tags as Web Components: their own look in a shadow root, with
  // parts (::part(paper) …) and --dsh-* variables left for a card to restyle.
  var L=${jsonEncode(labels.toJson())};
  function fill(s,k,v){return s.split('{'+k+'}').join(v);}
  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  var base=':host{display:block;margin:6px 0;color:var(--dsh-text);font:inherit;font-style:normal;}'+
    '[part~=card]{border:1px solid var(--dsh-card-border,rgba(127,127,127,.28));border-radius:14px;padding:12px 14px;background:var(--dsh-card,rgba(127,127,127,.06));}'+
    '[part~=head]{display:flex;gap:8px;align-items:baseline;font-weight:600;font-size:.92em;}'+
    '[part~=head] [part~=title]{flex:1;color:var(--dsh-accent);}'+
    '[part~=meta]{font-weight:400;font-size:.8em;color:var(--dsh-muted);}'+
    '[part~=body]{margin-top:8px;}';
  function define(tag,css,html){
    if(customElements.get(tag))return;
    customElements.define(tag,class extends HTMLElement{
      connectedCallback(){
        if(this.shadowRoot)return;
        var root=this.attachShadow({mode:'open'});
        root.innerHTML='<style>'+base+css+'</style>'+html(this);
      }
    });
  }
  function attr(el,names){for(var i=0;i<names.length;i++){var v=el.getAttribute(names[i]);if(v&&v.trim())return v.trim();}return null;}
  define('dsh-letter','[part~=card]{background:var(--dsh-letter-paper,rgba(232,211,166,.24));line-height:1.75;}',function(el){
    var from=attr(el,['from','sender','author']);var date=attr(el,['date','time']);
    return '<div part="card paper"><div part="head"><span part="title">'+esc(from?fill(L.letterFrom,'from',from):L.letter)+'</span>'+(date?'<span part="meta">'+esc(date)+'</span>':'')+'</div><div part="body"><slot></slot></div></div>';
  });
  define('dsh-item','[part~=card]{display:flex;gap:12px;align-items:flex-start;padding:10px 14px 10px 12px;}[part~=icon]{width:34px;height:34px;border-radius:10px;background:var(--dsh-item-icon,rgba(127,127,127,.14));display:flex;align-items:center;justify-content:center;flex:none;}[part~=name]{font-weight:600;}[part~=taken]{margin-left:8px;font-size:.75em;padding:1px 7px;border-radius:6px;background:var(--dsh-item-taken,rgba(60,160,90,.18));}[part~=body]{margin-top:2px;font-size:.88em;color:var(--dsh-muted);}',function(el){
    var name=attr(el,['name','title']);var taken=el.hasAttribute('take')||el.hasAttribute('taken');
    return '<div part="card item"><div part="icon">✦</div><div><div><span part="name">'+esc(name||'')+'</span>'+(taken?'<span part="taken">'+esc(L.taken)+'</span>':'')+'</div><div part="body"><slot></slot></div></div></div>';
  });
  define('dsh-clue',':host{transform:rotate(-.7deg);}[part~=card]{background:var(--dsh-clue-note,rgba(245,215,110,.28));}',function(el){
    var title=attr(el,['title','name']);
    return '<div part="card note"><div part="head"><span part="title">'+esc(title||L.clue)+'</span></div><div part="body"><slot></slot></div></div>';
  });
  define('dsh-phone','[part~=card]{max-width:360px;}[part~=bubble]{margin-top:8px;padding:8px 12px;border-radius:4px 14px 14px 14px;background:var(--dsh-phone-bubble,rgba(127,127,127,.14));}',function(el){
    var from=attr(el,['from','sender','name']);var time=attr(el,['time','date']);
    return '<div part="card phone"><div part="head"><span part="title">'+esc(from?fill(L.phoneFrom,'from',from):L.phone)+'</span>'+(time?'<span part="meta">'+esc(time)+'</span>':'')+'</div><div part="bubble"><slot></slot></div></div>';
  });
  define('dsh-roll','[part~=head]{align-items:center;}[part~=score]{font-variant-numeric:tabular-nums;}[part~=result]{font-weight:700;}.ok{color:var(--dsh-success,#2f8a4c);}.bad{color:var(--dsh-danger,#c0392b);}[part~=body]{margin-top:4px;font-size:.8em;color:var(--dsh-muted);}',function(el){
    var skill=attr(el,['skill','check','name','title']);var value=attr(el,['value','roll','score']);var target=attr(el,['target','dc','difficulty','against']);var result=attr(el,['result','outcome']);
    var r=(result||'').toLowerCase();var ok=/^(success|pass|passed|succeeded|成功|大成功|通过)\$/.test(r);var bad=/^(fail|failure|failed|失败|大失败)\$/.test(r);
    var label=ok?L.success:(bad?L.failure:result);
    var score=[value,target].filter(function(x){return x;}).join(' / ');
    return '<div part="card roll"><div part="head"><span part="title">'+esc(skill?fill(L.rollCheck,'skill',skill):L.roll)+'</span>'+(score?'<span part="score">'+esc(score)+'</span>':'')+(label?'<span part="result" class="'+(ok?'ok':bad?'bad':'')+'">'+esc(label)+'</span>':'')+'</div><div part="body"><slot></slot></div></div>';
  });
  define('dsh-notice',':host{text-align:center;font-size:.85em;color:var(--dsh-muted);}',function(){return '<slot></slot>';});
  define('dsh-game',':host{text-align:center;font-size:.85em;color:var(--dsh-muted);}',function(){return '▷ '+esc(L.game);});
  post({type:'ready'});
})();
</script></body></html>''';
}
