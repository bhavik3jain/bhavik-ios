import Foundation

extension FinanceReportHTML {
    /// The page's whole stylesheet, inline: the report is one self-contained
    /// file that is shown in a phone-width web view, a Mac window, saved as a
    /// PDF and shared, so it can load nothing (no fonts, no images, no
    /// scripts from anywhere).
    ///
    /// The palette is the design's (Report artboard), light by default and
    /// dark under `prefers-color-scheme`. PDF export and printing always
    /// render light, so the light palette has to be complete on its own.
    static let stylesheet: String = """
    :root{color-scheme:light dark;\
    --page:#f9f9f7;--surface:#fcfcfb;--text:#0b0b0b;--text2:#52514e;--muted:#76746e;--grid:#e1e0d9;--axis:#c3c2b7;\
    --border:rgba(11,11,11,.10);--track:#eeede8;\
    --s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--s5:#e87ba4;--s6:#8a5cd6;\
    --good:#0a7d0a;--goodbg:rgba(12,163,12,.10);--bad:#c03030;--badbg:rgba(208,59,59,.10);--badfill:#d03b3b;\
    --warn:#ec835a;--warnbg:rgba(236,131,90,.20);--warntext:#7a3a17;\
    --ai:#6E3FD0;--aitext:#5A2FB5;--aiborder:rgba(110,63,208,.28)}
    @media (prefers-color-scheme:dark){:root{\
    --page:#0d0d0d;--surface:#1a1a19;--text:#ffffff;--text2:#c3c2b7;--muted:#9a988f;--grid:#2c2c2a;--axis:#46463f;\
    --border:rgba(255,255,255,.10);--track:#262624;\
    --s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--s6:#9b72e6;\
    --good:#4cc94c;--goodbg:rgba(76,201,76,.14);--bad:#ff6b6b;--badbg:rgba(255,107,107,.14);--badfill:#e05252;\
    --warn:#ec835a;--warnbg:rgba(236,131,90,.22);--warntext:#f3b496;\
    --ai:#a98bf0;--aitext:#c2acf7;--aiborder:rgba(169,139,240,.34)}}
    *{box-sizing:border-box}
    html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
    body{margin:0;background:var(--page);color:var(--text);\
    font:15px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
    .wrap{max-width:960px;margin:0 auto;padding:56px 24px 80px;display:flex;flex-direction:column;gap:16px}
    header.top{display:flex;flex-direction:column;gap:10px;margin-bottom:12px}
    header.top h1{margin:0;font-size:clamp(28px,7vw,36px);line-height:1.1;letter-spacing:-.02em}
    header.top p{margin:0;color:var(--text2);max-width:64ch}
    section,[id]{scroll-margin-top:16px}
    h2{font-size:19px;margin:0 0 6px;letter-spacing:-.01em}
    h3{font-size:13.5px;margin:22px 0 10px;color:var(--text2);font-weight:600}
    .lbl{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
    .lede{margin:0 0 18px;color:var(--text2);max-width:66ch;font-size:14px}
    .note{font-size:12px;color:var(--muted);margin:8px 0 0}
    .card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:24px;min-width:0}
    .hero{display:flex;gap:28px;align-items:center;flex-wrap:wrap;padding:28px 26px}
    .hero .main{flex:1 1 320px;min-width:0}
    .hero .big{font-size:clamp(40px,11vw,54px);line-height:1.05;font-weight:650;letter-spacing:-.03em;margin:8px 0 12px;font-variant-numeric:tabular-nums}
    .hero .sub{display:flex;gap:10px;align-items:center;flex-wrap:wrap;font-size:13.5px;color:var(--text2)}
    .hero svg{flex:0 1 300px;max-width:100%;height:auto}
    .pill{font-weight:600;padding:2px 9px;border-radius:10px;font-variant-numeric:tabular-nums}
    .pill.good{color:var(--good);background:var(--goodbg)}
    .pill.bad{color:var(--bad);background:var(--badbg)}
    .pill.flat{color:var(--text2);background:var(--track)}
    .pill.warn{color:var(--warntext);background:var(--warnbg)}
    .good{color:var(--good)}.bad{color:var(--bad)}.flat{color:var(--muted)}
    .brief{border-color:var(--aiborder);display:flex;flex-direction:column;gap:16px}
    .brief.plain{border-color:var(--border)}
    .brief .kick{display:flex;align-items:center;gap:8px;color:var(--aitext)}
    .brief.plain .kick{color:var(--muted)}
    .brief .kick .lbl{color:inherit}
    .brief .head{margin:0;font-size:18px;line-height:1.45;font-weight:560;max-width:62ch}
    .brief .cols{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(240px,100%),1fr));gap:20px}
    .brief .foot{font-size:12px;color:var(--muted);border-top:1px solid var(--border);padding-top:12px}
    .bc{display:flex;flex-direction:column;gap:8px}
    .bc ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:8px}
    .bc li{font-size:13.5px;line-height:1.45;color:var(--text2)}
    .bc .lbl.ww{color:var(--good)}.bc .lbl.tw{color:var(--warntext)}.bc .lbl.tt{color:var(--aitext)}
    .brief.plain .bc .lbl.tt{color:var(--s1)}
    .grid{display:grid;gap:10px}
    .kpis{grid-template-columns:repeat(auto-fit,minmax(min(160px,100%),1fr));margin-bottom:12px}
    .minis{grid-template-columns:repeat(auto-fit,minmax(min(150px,100%),1fr))}
    .pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(420px,100%),1fr));gap:16px}
    .halves{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(380px,100%),1fr));gap:28px;margin-top:6px}
    .kpi{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px;min-width:0}
    .kpi .l{font-size:12px;color:var(--muted)}
    .kpi .v{font-size:21px;font-weight:620;letter-spacing:-.02em;margin:5px 0 3px;font-variant-numeric:tabular-nums}
    .kpi .s{font-size:11.5px;color:var(--muted)}
    .mini{padding:12px 14px;border:1px solid var(--border);border-radius:10px;min-width:0}
    .mini .l{font-size:11.5px;color:var(--muted)}
    .mini .v{font-size:18px;font-weight:600;letter-spacing:-.02em;margin:4px 0 2px;font-variant-numeric:tabular-nums}
    .mini .s{font-size:11px;color:var(--muted)}
    .stack{display:flex;gap:2px;height:34px}
    .stack div{border-radius:3px;min-width:3px}
    .legend{display:flex;flex-direction:column;margin-top:16px}
    .lg{display:flex;align-items:center;gap:10px;font-size:13px;padding:4px 0}
    .lg.hd{font-size:11.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
    .lg.hd .n{color:var(--muted)}
    .sw{width:11px;height:11px;border-radius:3px;flex:none;display:inline-block}
    .sw.dot{border-radius:50%}
    .lg .n{flex:1;color:var(--text2);min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .lg .v{font-variant-numeric:tabular-nums;font-weight:560;width:96px;text-align:right}
    .lg .p{width:56px;text-align:right;color:var(--muted);font-variant-numeric:tabular-nums}
    .lg .d{width:96px;text-align:right;font-variant-numeric:tabular-nums;font-size:12.5px}
    .rows{display:flex;flex-direction:column;gap:5px}
    .br{display:grid;grid-template-columns:minmax(90px,1fr) minmax(0,1.1fr) 92px;gap:12px;align-items:center;padding:2px 4px;border-radius:6px}
    .br .bl{font-size:12.5px;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .br .bl span{color:var(--muted)}
    .br .bt{height:18px;display:flex;align-items:center}
    .br .bf{height:18px;border-radius:0 4px 4px 0;min-width:2px}
    .br .bv{font-size:12.5px;text-align:right;font-variant-numeric:tabular-nums}
    .oc{background:var(--ocl)}
    @media (prefers-color-scheme:dark){.oc{background:var(--ocd)}}
    .mv{display:grid;grid-template-columns:minmax(90px,200px) minmax(0,1fr) 84px;gap:12px;align-items:center;font-size:12.5px;padding:2px 4px}
    .mv .n{color:var(--text2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .mv .t{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));height:18px}
    .mv .t div{display:flex;align-items:center}
    .mv .t div:first-child{justify-content:flex-end}
    .mv .t div:last-child{border-left:1px solid var(--axis)}
    .mv .t i{display:block;height:16px}
    .mv .t .neg{background:var(--badfill);border-radius:3px 0 0 3px}
    .mv .t .pos{background:var(--s3);border-radius:0 3px 3px 0}
    .mv .val{text-align:right;font-variant-numeric:tabular-nums;font-weight:560}
    .owners{display:flex;flex-wrap:wrap;gap:14px;margin-top:12px;font-size:12px;color:var(--muted)}
    .owners span{display:flex;align-items:center;gap:6px}
    .keys{display:flex;flex-wrap:wrap;gap:18px;margin-bottom:10px;font-size:12.5px;color:var(--text2)}
    .keys span{display:flex;align-items:center;gap:7px}
    .dumb{display:grid;grid-template-columns:minmax(90px,200px) minmax(0,1fr) 62px;gap:12px;align-items:center;padding:3px 4px}
    .dumb .n{font-size:12.5px;color:var(--text2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .dumb .tr{position:relative;height:18px}
    .dumb .cn{position:absolute;top:8px;height:2px;background:var(--axis);border-radius:2px}
    .dumb .dt{position:absolute;top:4px;width:10px;height:10px;border-radius:50%;margin-left:-5px;box-shadow:0 0 0 2px var(--surface)}
    .dumb .ch{text-align:right;font-size:12.5px;font-variant-numeric:tabular-nums}
    .buds{display:flex;flex-direction:column;gap:12px}
    .bud{display:flex;flex-direction:column;gap:6px}
    .bud .top{display:flex;justify-content:space-between;gap:12px;font-size:13px;color:var(--text2)}
    .bud .top span:last-child{font-variant-numeric:tabular-nums;color:var(--text);text-align:right}
    .bud .top span.over{color:var(--bad)}
    .bud .trk{height:10px;border-radius:5px;background:var(--track);overflow:hidden;display:flex;gap:1px}
    .bud .in{background:var(--s1)}.bud .ov{background:var(--badfill)}
    .nobud{display:flex;flex-direction:column;gap:8px;margin-top:18px;border-top:1px solid var(--border);padding-top:14px}
    .chips{display:flex;flex-wrap:wrap;gap:6px}
    .chip{background:var(--track);border-radius:12px;padding:3px 10px;font-size:12.5px;color:var(--text2)}
    .meter{height:14px;border-radius:7px;background:var(--track);overflow:hidden}
    .meter div{height:100%;background:var(--s1);border-radius:7px}
    .cols-chart{display:flex;align-items:flex-end;gap:6px;height:150px;padding-top:6px;border-bottom:1px solid var(--axis)}
    .cols-chart .c{flex:1 1 0;display:flex;flex-direction:column;justify-content:flex-end;align-items:stretch;height:100%;min-width:0}
    .cols-chart .c i{display:block;background:var(--s1);border-radius:3px 3px 0 0;min-height:1px}
    .cols-chart .c i.cash{background:var(--s2);border-radius:0}
    .cols-labels{display:flex;gap:6px;font-size:10.5px;color:var(--muted);margin-top:4px}
    .cols-labels span{flex:1 1 0;text-align:center;min-width:0;overflow:hidden}
    .fixes{display:flex;flex-direction:column;gap:16px}
    .fd{border-left:3px solid var(--axis);padding:2px 0 2px 16px}
    .fd.warn{border-left-color:var(--warn)}
    .fd p{margin:6px 0 0;font-size:13.5px;color:var(--text2);max-width:70ch}
    .fd h4{margin:0;font-size:14.5px}
    .fh{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
    .bdg{font-size:10.5px;text-transform:uppercase;letter-spacing:.05em;padding:2px 7px;border-radius:20px;font-weight:600;white-space:nowrap;background:var(--track);color:var(--muted)}
    .fd.warn .bdg{background:var(--warnbg);color:var(--warntext)}
    details{margin-top:18px;border-top:1px solid var(--border);padding-top:12px}
    summary{cursor:pointer;font-size:12.5px;color:var(--text2);list-style:none}
    summary::-webkit-details-marker{display:none}
    summary::before{content:"\\203A\\00a0";display:inline-block;transition:transform .15s}
    details[open] summary::before{transform:rotate(90deg)}
    .tbl{overflow-x:auto;-webkit-overflow-scrolling:touch}
    details .tbl{margin-top:10px}
    table{border-collapse:collapse;width:100%;font-size:12.5px}
    th,td{padding:7px 10px;border-bottom:1px solid var(--grid);white-space:nowrap}
    th{text-align:left;color:var(--muted);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em}
    td{font-variant-numeric:tabular-nums;color:var(--text2)}
    td.wrap{white-space:normal}
    .ar{text-align:right}
    svg text{font-family:inherit}
    .chart-n{display:none}
    footer{margin-top:20px;font-size:12px;color:var(--muted);text-align:center;line-height:1.6}
    @media (max-width:600px){
    .wrap{padding:24px 16px 48px;gap:12px}
    .mv,.dumb{grid-template-columns:minmax(70px,120px) minmax(0,1fr) 78px;gap:8px}
    .br{grid-template-columns:minmax(0,1fr) auto!important;row-gap:3px;column-gap:10px;padding:3px 0}
    .br .bl{white-space:normal}
    .br .bt{grid-column:1/-1;grid-row:2;height:12px}
    .br .bf{height:12px}
    th,td{padding:7px 6px}
    td:not(.ar){white-space:normal;min-width:72px}
    .lg .d{display:none}
    .card{padding:18px 14px}
    .hero{padding:20px 16px;gap:18px}
    .halves{gap:12px}
    .chart-w{display:none}.chart-n{display:block}
    }
    @media print{
    *{-webkit-print-color-adjust:exact;print-color-adjust:exact}
    body{background:#fff}
    .wrap{padding:0;max-width:none}
    .card,.kpi,.mini,.fd,.bud,.br,.mv,.dumb,tr{break-inside:avoid;page-break-inside:avoid}
    details{display:none}
    .chart-w{display:block}.chart-n{display:none}
    }
    """
}
