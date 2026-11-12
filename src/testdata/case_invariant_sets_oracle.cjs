const html = String.raw`<([a-z][a-z0-9-]*)((?:\s+(?:[^>"']|"[^"]*"|'[^']*')*)*)>`;
const whitespace = [9,10,11,12,13,32,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279];
const inputs = ['', 'abc', 'Kk\u212a', 'sS\u017f', '<div>', '<DIV X="a > b" foo=\'c\'>tail', '<x   a=b >', '<x >', '<x a="unterminated>', '<x a=\'unterminated>', '<x\n data-x="v">', '<x> <Y a=\'b\'>', '<x a="v"><y b="w">', ...whitespace.map(cp => '<TAG'+String.fromCodePoint(cp)+'a="v">'), ...whitespace.map(cp => String.fromCodePoint(cp)+'X'+String.fromCodePoint(cp))];
const specs = [[html,'gis',true], [html,'gims',true], [String.raw`(\s+)`,'i',true], [String.raw`(\s+)`,'iu',true], [String.raw`(\s+)`,'iv',true], [String.raw`(\s*)X(\s*)`,'i',true], [String.raw`([\s\S]+)`,'i',true], [String.raw`[\s]`,'iv',true], [String.raw`\S`,'iu',false], [String.raw`[^\s]`,'iv',false], [String.raw`[Kk]`,'iv',false], [String.raw`[sS]`,'iv',false], [String.raw`[\q{ab}]`,'iv',false], [String.raw`[\s\S]`,'iv',false], [String.raw`([\s\S]+)`,'',true], [String.raw`([\s\S]+)`,'s',true]];
const output = specs.map(([source,flags,nfa]) => ({source,flags,nfa,cases:inputs.flatMap(input => [0,1].filter(from => from <= input.length).map(from => {
 const re=new RegExp(source,flags.replace('g','')+'g');re.lastIndex=from;const m=re.exec(input);
 const byte=offset=>Buffer.byteLength(input.slice(0,offset));
 return {input,from:byte(from),match:m?{start:byte(m.index),end:byte(m.index+m[0].length),captures:Array.from(m).slice(1).map(v=>v===undefined?null:v)}:null};
}))}));
console.log(JSON.stringify({node:process.version,checks:output.reduce((n,x)=>n+x.cases.length,0),output},null,2));
