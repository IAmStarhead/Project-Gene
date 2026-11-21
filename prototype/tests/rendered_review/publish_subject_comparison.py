#!/usr/bin/env python3
"""Verify identical real input/physics/observer and publish full-source before/after.

No image crop, rescaling, retouch, pose injection or video interpolation.
Every output frame contains the two UNCHANGED 800x450 native framebuffers.
The extra captions are outside the game pixels. This is not GPU/Windows proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate(before, after):
    for data in [before,after]:
        if data['errors'] or data.get('coverage_assertions_passed') is not True:
            raise ValueError('Unsuccessful native capture')
        if data['config']['coverage'] != 'subject-comparison' or data['config']['sample_ticks'] != 6:
            raise ValueError('Expected the explicit uniformly sampled subject comparison')
    if before['config']['timeline'] != after['config']['timeline']:
        raise ValueError('Different actual input/fixture timelines')
    if len(before['frames']) != len(after['frames']) or not before['frames']:
        raise ValueError('Different frame inventories')
    for key in ['world_sha256','lighting_sha256','camera_sha256','model_sha256','clone_sha256','project_sha256']:
        if before['source_hashes'][key] != after['source_hashes'][key]:
            raise ValueError('Changed protected production source '+key)
    lower = ['hips','spine','chest','neck','head','thigh.L','shin.L','foot.L','toe.L',
             'thigh.R','shin.R','foot.R','toe.R']
    # Original imported order is part of the frozen model identity above.
    model_bones = ['hips','spine','chest','neck','head','shoulder.L','upper_arm.L',
                   'forearm.L','hand.L','shoulder.R','upper_arm.R','forearm.R','hand.R',
                   'thigh.L','shin.L','foot.L','toe.L','thigh.R','shin.R','foot.R','toe.R']
    lower_indices = [model_bones.index(name) for name in lower]
    pairs = []
    for a,b in zip(before['frames'],after['frames']):
        for key in ['take','ticks','steps','viewport','view','yaw','camera_yaw',
                    'velocity','grounded','action','action_time']:
            if a[key] != b[key]:
                raise ValueError('Different physical/observer state '+a['take']+'/'+key)
        if len(a['camera_transform']) != 12 or a['camera_transform'] != b['camera_transform']:
            raise ValueError('Different numerical observer transform '+a['take'])
        if a['player']['position'] != b['player']['position']:
            raise ValueError('Different actual CharacterBody position '+a['take'])
        if a['take'] in ['subject-front','subject-back','walk','jog','stop']:
            if a['player']['hips'] != b['player']['hips']:
                raise ValueError('Changed accepted pelvis '+a['take'])
            for i in lower_indices:
                if a['player']['rotations'][i] != b['player']['rotations'][i]:
                    raise ValueError('Changed non-arm gait key '+a['take']+'/'+model_bones[i])
        for f in [a,b]:
            if sha(f['file']) != f['sha256']:
                raise ValueError('Changed original capture '+f['file'])
        pairs.append((a,b))
    return pairs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before',type=Path,required=True)
    parser.add_argument('--after',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--font',default='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
    args = parser.parse_args()
    before,after = [json.loads(p.read_text()) for p in [args.before,args.after]]
    pairs = validate(before,after)
    provenance = {}
    for label,data,commit in [('before',before,'c9d24b157ce7f8366f9a2712e87c01619192cfc8'),
                              ('after',after,None)]:
        metadata = Path(data['config']['hashes']).parent/'pack.json'
        pack = json.loads(metadata.read_text())
        if (pack['source_hashes'] != data['source_hashes'] or pack['driver'] != 'game'
                or pack['production_source_commit'] != commit
                or pack['baseline_appearance_commit'] is not None
                or pack['strict_import_and_pack_pass'] is not True):
            raise ValueError('Not the stated full-production build: '+label)
        provenance[label] = pack | {'metadata_sha256':sha(metadata)}
    if provenance['before']['driver_sha256'] != provenance['after']['driver_sha256']:
        raise ValueError('Before/after use different review drivers')
    from PIL import Image,ImageDraw,ImageFont
    font,small = ImageFont.truetype(args.font,16),ImageFont.truetype(args.font,13)
    args.out.mkdir(parents=True,exist_ok=True)
    size,header,footer = (800,450),54,48

    def frame(pair,index):
        canvas = Image.new('RGB',(size[0]*2,size[1]+header+footer),'#152331')
        draw = ImageDraw.Draw(canvas)
        for col,(f,title) in enumerate(zip(pair,['BEFORE | c9d24b1 | full production baseline','AFTER | R57 | current production'])):
            with Image.open(f['file']) as image:
                if image.size != size: raise ValueError('Unexpected native framebuffer size')
                canvas.paste(image.convert('RGB'),(col*size[0],header))
            draw.text((col*size[0]+10,7),title,font=font,fill='#e1f0f7')
            draw.text((col*size[0]+10,31),f['label'],font=small,fill='white')
        draw.text((10,header+size[1]+5),f'1x simulation | 10 captured pairs/s | 60 Hz physics | pair {index+1}/{len(pairs)} | camera / root physics EXACTLY equal',font=small,fill='white')
        draw.text((10,header+size[1]+26),'REAL Godot controllers / same observer + fixtures | no interpolation, crop or rescale | offline WebGL2 / SwiftShader, NOT 940MX FPS',font=small,fill='#bed4df')
        return canvas

    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        from imageio_ffmpeg import get_ffmpeg_exe
        ffmpeg = get_ffmpeg_exe()
    video = args.out/'before-after.mp4'
    command = [ffmpeg,'-y','-hide_banner','-loglevel','error','-f','rawvideo',
        '-pixel_format','rgb24','-video_size','1600x552','-framerate','10','-i','pipe:0',
        '-an','-c:v','libx264','-preset','medium','-crf','19','-pix_fmt','yuv420p',
        '-movflags','+faststart',str(video)]
    process = subprocess.Popen(command,stdin=subprocess.PIPE)
    try:
        for i,pair in enumerate(pairs): process.stdin.write(frame(pair,i).tobytes())
    finally:
        process.stdin.close()
        code = process.wait()
    if code: raise RuntimeError('ffmpeg returned '+str(code))
    selections = {}
    for take in ['subject-front','subject-back']:
        selections[take] = next(i for i,pair in enumerate(pairs) if pair[0]['take']==take)
    airborne = [i for i,pair in enumerate(pairs) if pair[0]['take']=='relaxed-jump']
    selections['jump-apex'] = max(airborne,key=lambda i:pairs[i][0]['player']['position'][1])
    jogging = [i for i,pair in enumerate(pairs) if pair[0]['take']=='jog']
    selections['jog'] = min(jogging,key=lambda i:abs(pairs[i][0]['player']['phase']-.25))
    selected = []
    for name,i in selections.items():
        path = args.out/('comparison-'+name+'.png')
        frame(pairs[i],i).save(path)
        selected.append({'file':path.name,'sha256':sha(path),'pair':i,
            'before_source_png':pairs[i][0]['sha256'],'after_source_png':pairs[i][1]['sha256']})
    evidence = {'video':video.name,'sha256':sha(video),'frames':len(pairs),
        'distinct_before_pngs':before['unique_pngs'],'distinct_after_pngs':after['unique_pngs'],
        'physics_hz':60,'capture_hz':10,'playback_simulation_rate':1,'seconds':len(pairs)/10,
        'viewport_per_cell':list(size),'video_pixels':[1600,552],
        'input_timeline_exactly_equal':True,'root_physics_and_observer_exact_pairs':len(pairs),
        'old_gait_nonarm_exact_pairs':sum(a['take'] in ['subject-front','subject-back','walk','jog','stop'] for a,b in pairs),
        'before_manifest_sha256':sha(args.before),'after_manifest_sha256':sha(args.after),
        'source_hashes':{'before':before['source_hashes'],'after':after['source_hashes']},
        'pack_provenance':provenance,
        'selected_stills':selected,'timeline':before['config']['timeline'],
        'conditions':'Full c9d24b1 production archive versus current production, same current review driver; only entry point/starting fixtures/observer/UI visibility are review-only. All physical root positions, velocities, grounded flags and observer transforms exactly equal per pair; old gait non-arm keys also checked. No crop/rescale/retouch/interpolation; captions outside original game pixels. Offline Godot Compatibility/WebGL2/SwiftShader, no audio, NOT continuous manual review / Windows / 940MX performance.'}
    (args.out/'before-after.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(video,':',len(pairs),'exact physics/camera pairs,',len(pairs)/10,'s at 1x')


if __name__=='__main__': main()
