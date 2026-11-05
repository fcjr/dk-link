"""Runs inside TouchDesigner, driven frame by frame from the test project's
Execute DAT onFrameEnd. Creates the DK Link TOP and CHOP, cycles
the Image menu saving each, dumps the CHOP channels and node errors to
$DKLINK_TD_TEST_OUT/report.json, and quits."""
import os, json, traceback

OUT = os.environ.get('DKLINK_TD_TEST_OUT', '/tmp/dklink-td-test')
os.makedirs(OUT, exist_ok=True)
S = {'report': {'version': app.version, 'build': app.build, 'steps': [], 'images': {}},
     'frame': 0, 'ready': False, 'done': False}

WANTED = ['color', 'depth', 'ir', 'pointcloud', 'playerindex', 'colorremap', 'depthremap', 'pointcloudremap']

def log(*a):
    S['report']['steps'].append(' '.join(str(x) for x in a))

def write():
    with open(os.path.join(OUT, 'report.json'), 'w') as f:
        json.dump(S['report'], f, indent=1, default=str)

def finish():
    if S['done']:
        return
    S['done'] = True
    write()
    project.quit(force=True)

def setup():
    r = S['report']
    project_comp = op('/project1')
    if project_comp.op('test'):
        project_comp.op('test').destroy()
    parent = project_comp.create(baseCOMP, 'test')
    S['parent'] = parent
    top = parent.create('DklinkTOP', 'dklink')
    chop = parent.create('DklinkCHOP', 'skeleton')
    S['top'], S['chop'] = top, chop
    log('created', top.OPType, chop.OPType)
    top.par.Active = 1
    top.par.Bodytracking = 0   # the CHOP alone must switch tracking on
    chop.par.Active = 1
    r['top_pars'] = [p.name for p in top.pars() if p.name[0].isupper()]
    r['chop_pars'] = [p.name for p in chop.pars() if p.name[0].isupper()]
    r['image_menu'] = list(top.par.Image.menuNames)
    S['ready'] = True
    write()

def on_frame():
    if S['done']:
        return
    if not S['ready']:
        try:
            setup()
        except Exception:
            S['report']['exception'] = traceback.format_exc()
            finish()
        return
    top, chop, parent = S['top'], S['chop'], S['parent']
    try:
        # The camera takes a few seconds to deliver its first frame: wait for
        # the Info CHOP's frame counter before the schedule starts (20 s cap).
        if 'info' not in S:
            info = parent.create('infoCHOP', 'info')
            info.par.op = top.path
            dat = parent.create('infoDAT', 'infodat')
            dat.par.op = top.path
            S['info'], S['dat'], S['waited'] = info, dat, 0
            return
        if S['frame'] == 0:
            S['waited'] += 1
            frame_count = S['info']['image_frame'][0] if S['info'].numChans else 0
            if frame_count > 0 or S['waited'] > 1200:
                S['report']['first_frame_wait_frames'] = S['waited']
                S['report']['info_dat'] = [[c.val for c in r] for r in S['dat'].rows()]
                log('first frame after', S['waited'], 'frames' if frame_count > 0 else 'frames (timed out)')
            else:
                return
        S['frame'] += 1
        f = S['frame']
        if f == 150:
            info = S['info']
            S['report']['info_chop'] = {c.name: round(c[0], 4) for c in info.chans()}
            S['report']['info_dat'] = [[c.val for c in r] for r in S['dat'].rows()]
            S['report']['chop_num_chans'] = chop.numChans
            S['report']['chop_channels'] = {c.name: round(c[0], 4) for c in chop.chans()}
            S['report']['errors'] = {'top': top.errors(), 'chop': chop.errors(), 'top_warn': top.warnings(), 'chop_warn': chop.warnings()}
            write()
        if f >= 160:
            # 1.5 s per image: the library computes a kind only once asked for,
            # and the first request after a switch returns nothing.
            idx = (f - 160) // 90
            phase = (f - 160) % 90
            if idx >= len(WANTED):
                chop = S['chop']
                S['report']['chop_final'] = {'warn': chop.warnings(), 'tracked': chop['p1/tracked'][0] if chop.numChans else None,
                                             'id': chop['p1/id'][0] if chop.numChans else None,
                                             'pelvis_z': chop['p1/pelvis:tz'][0] if chop.numChans else None,
                                             'info': {c.name: round(c[0], 3) for c in S['info'].chans() if c.name.startswith('bodytracking')}}
                log('all images cycled'); finish(); return
            name = WANTED[idx]
            if phase == 0:
                top.par.Image = name
            elif phase == 60:
                ext = '.exr' if name in ('depth', 'depthremap', 'pointcloud', 'pointcloudremap') else '.png'
                path = os.path.join(OUT, name + ext)
                try:
                    top.save(path)
                    S['report']['images'][name] = {'res': [top.width, top.height], 'fmt': str(top.pixelFormat), 'warnings': top.warnings(), 'file': path,
                                                   'par': top.par.Image.eval(), 'par_index': top.par.Image.menuIndex,
                                                   'info_image': [[c.val for c in r] for r in S['dat'].rows() if r and r[0].val == 'image'],
                                                   'image_frame': S['info']['image_frame'][0] if S['info'].numChans else None}
                    log('saved', name, top.width, top.height)
                except Exception as e:
                    S['report']['images'][name] = {'error': repr(e), 'warnings': top.warnings()}
                write()
        if f > 1500:
            log('frame timeout'); finish()
    except Exception:
        S['report']['exception'] = traceback.format_exc()
        finish()
