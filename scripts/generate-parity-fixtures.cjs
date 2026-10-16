// Explicit regeneration only: node scripts/generate-parity-fixtures.cjs /path/to/electron-checkout
// Runs the independent Electron/WebGL renderer; never imports Linse's Metal implementation.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync, spawnSync } = require('node:child_process');

const reference = path.resolve(process.argv[2] || '../ai-ps');
const output = path.resolve(__dirname, '../Tests/LinseCoreTests/Fixtures/Electron');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'linse-reference-'));
const esbuild = require(path.join(reference, 'node_modules/esbuild'));
const electron = require(path.join(reference, 'node_modules/electron'));
const source = name => JSON.stringify(path.join(reference, 'src/renderer', name));

try {
    const bundle = esbuild.buildSync({
        stdin: { contents: `
            import { Renderer } from ${source('pipeline.ts')};
            import { defaultParams, normalizeParams } from ${source('params.ts')};
            import { BUILTIN } from ${source('presets.ts')};
            const width = 64, height = 48;
            const pixels = new Uint8ClampedArray(width * height * 4);
            for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
                const i = (y * width + x) * 4;
                const gray = Math.round(x * 255 / (width - 1));
                pixels[i] = gray;
                pixels[i + 1] = y < 12 ? gray : Math.round(y * 255 / (height - 1));
                pixels[i + 2] = y < 12 ? gray : (x * 13 + y * 7) % 256;
                pixels[i + 3] = 255;
            }
            const canvas = document.createElement('canvas');
            canvas.width = width; canvas.height = height;
            canvas.getContext('2d').putImageData(new ImageData(pixels, width, height), 0, 0);
            const renderer = new Renderer();
            renderer.setImage(canvas, width, height);
            const curves = defaultParams();
            curves.curves.rgb = [[0, 18], [90, 110], [200, 185], [255, 245]];
            curves.curves.r = [[0, 0], [128, 145], [255, 255]];
            curves.curves.g = [[0, 0], [128, 110], [255, 255]];
            curves.curves.b = [[0, 15], [255, 240]];
            const hsl = defaultParams();
            for (const [i, band] of Object.keys(hsl.hsl).entries()) hsl.hsl[band] = { hue: i % 2 ? 25 : -20, sat: 35 - i * 10, lum: i * 5 - 15 };
            const cases = [{ id: 'identity', params: defaultParams() },
                ...BUILTIN.map(p => ({ id: p.id, params: normalizeParams(p.params) })),
                { id: 'channel-curves', params: curves }, { id: 'all-hsl', params: hsl }];
            window.parityFixture = { width, height, source: Array.from(pixels), cases: cases.map(c => {
                renderer.render(c.params, width, height);
                const raw = renderer.readPixels(), topDown = new Uint8Array(raw.length);
                for (let y = 0; y < height; y++) topDown.set(raw.subarray((height - 1 - y) * width * 4, (height - y) * width * 4), y * width * 4);
                return { ...c, pixels: Array.from(topDown) };
            }) };
        `, resolveDir: reference, loader: 'ts' },
        bundle: true, write: false, metafile: true, platform: 'browser', format: 'iife',
    });
    const hashes = {};
    for (const input of Object.keys(bundle.metafile.inputs).filter(p => !p.startsWith('<'))) {
        const absolute = path.resolve(input);
        hashes[path.relative(reference, absolute)] = crypto.createHash('sha256').update(fs.readFileSync(absolute)).digest('hex');
    }
    fs.writeFileSync(path.join(scratch, 'renderer.js'), bundle.outputFiles[0].text);
    fs.writeFileSync(path.join(scratch, 'main.cjs'), `
        const { app, BrowserWindow } = require('electron');
        const fs = require('node:fs');
        app.setPath('userData', ${JSON.stringify(path.join(scratch, 'profile'))});
        app.whenReady().then(async () => {
            const window = new BrowserWindow({ show: false, webPreferences: { sandbox: true, backgroundThrottling: false } });
            await window.loadURL('data:text/html,<html><body></body></html>');
            await window.webContents.executeJavaScript(fs.readFileSync(${JSON.stringify(path.join(scratch, 'renderer.js'))}, 'utf8'));
            const result = await window.webContents.executeJavaScript('window.parityFixture');
            result.electronVersion = process.versions.electron;
            fs.writeFileSync(${JSON.stringify(path.join(scratch, 'result.json'))}, JSON.stringify(result));
            app.quit();
        }).catch(error => { console.error(error); app.exit(1); });
    `);
    const env = { ...process.env };
    delete env.ELECTRON_RUN_AS_NODE;
    const run = spawnSync(electron, [path.join(scratch, 'main.cjs')], { env, encoding: 'utf8', timeout: 45000 });
    if (run.status !== 0) throw new Error(run.stderr || String(run.error || `Electron exited ${run.status}`));
    const result = JSON.parse(fs.readFileSync(path.join(scratch, 'result.json'), 'utf8'));
    const manifest = {
        width: result.width, height: result.height, format: 'RGBA8 sRGB encoded, rows top to bottom',
        reference: { commit: execFileSync('git', ['-C', reference, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
            electronVersion: result.electronVersion, sourceSHA256: hashes },
        cases: result.cases.map(({ id, params }) => ({ id, params })),
    };
    fs.mkdirSync(output, { recursive: true });
    fs.writeFileSync(path.join(output, 'source.rgba'), Buffer.from(result.source));
    for (const c of result.cases) fs.writeFileSync(path.join(output, c.id + '.rgba'), Buffer.from(c.pixels));
    fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
    console.log(`Wrote ${result.cases.length} Electron reference cases (${result.width}x${result.height}) to ${output}`);
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}
