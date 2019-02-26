#!/usr/bin/env xonsh
$RAISE_SUBPROC_ERROR = True
$XONSH_SHOW_TRACEBACK = True

import sys; sys.path.insert(0, '')
import _config
from _config import pjoin
from utils import PathRecover, log
import persistence as pst
import os
import repo
import argparse
import traceback
import time
import json
import shutil

$ceroot=_config.workspace
develop_evaluate=_config.develop_evaluate
os.environ['ceroot'] = _config.workspace
mode = os.environ.get('mode', 'evaluation')
specific_tasks = os.environ.get('specific_tasks', None)
specific_tasks = specific_tasks.split(',') if specific_tasks else []
case_type = os.environ.get('case_type', None)


def parse_args():
    parser= argparse.ArgumentParser("Tool for running CE models")
    parser.add_argument(
        '--modified',
        action='store_true',
        help='if set, we will just run modified models.')
    args = parser.parse_args()
    return args

def main():
    #try_start_mongod()
    args = parse_args()
    suc, exception_task = evaluate_tasks(args)
    if suc:
        display_success_info()
        if mode == "evaluation" and (not args.modified) and (not specific_tasks):
            update_baseline()
        exit 0
    else:
        if (not args.modified) and (not specific_tasks):
            display_fail_info(exception_task)
        sys.exit(-1)


def update_baseline():
    ''' update the baseline in a git repo using current base. '''
    log.warn('updating baseline')
    commit = repo.get_commit(_config.paddle_path)
    with PathRecover():
        message = "evalute [%s]" % commit
        for task_name in get_tasks():
            task_dir = pjoin(_config.baseline_path, task_name)
            cd @(task_dir)
            print('task_dir', task_dir)
            if os.path.isdir('latest_kpis'):
                # update baseline if the latest kpi is better than history
                tracking_kpis = get_kpi_tasks(task_name)

                for kpi in tracking_kpis:
                    # if the kpi is not actived, do not update baseline.
                    if not kpi.actived: continue
                    kpi.root = task_dir
                    better_ratio = kpi.compare_with(kpi.cur_data, kpi.baseline_data)
                    if  better_ratio > _config.kpi_update_threshold:
                        log.warn('current kpi %s better than history by %f, update baseline' % (kpi.out_file, better_ratio))
                        cp @(kpi.out_file) @(kpi.his_file)

        if $(git diff):
            log.warn('update github baseline')
            '''
            due to the selected update controled by `_config.kpi_update_threshold`, if one task passed, there might be no baselines to update.
            '''
            git pull origin master
            git commit -a -m @(message)
            git push
        else:
            log.warn('no baseline need to update')


def refresh_baseline_workspace():
    ''' download baseline. '''
    if mode != "baseline_test":
        # ssh from home is not very stable, can be solved by retry.
        max_retry = 10
        for cnt in range(max_retry):
            try:
                # production mode, clean baseline and rerun
                rm -rf @(_config.baseline_path)
                git clone @(_config.baseline_repo_url) @(_config.baseline_path)
                log.info("git clone %s suc" % _config.baseline_repo_url)
                break
            except Exception as e:
                if cnt == max_retry - 1:
                    raise Exception("git clone failed %s " % e)
                else:
                    log.warn('git clone failed %d, %s' % (cnt, e))
                    time.sleep(3)


def evaluate_tasks(args):
    '''
    Evaluate all the tasks. It will continue to run all the tasks even
    if any task is failed to get a summary.
    '''
    cd @(_config.workspace)
    print("_config.workspace", _config.workspace)
    paddle_commit = repo.get_commit(_config.paddle_path)
    commit_time = repo.get_commit_date(_config.paddle_path)
    log.warn('commit', paddle_commit)
    all_passed = True
    exception_task = {}
    
    # get tasks that need to evaluate
    if specific_tasks:
        tasks = specific_tasks
        log.warn('run specific tasks', tasks)
    elif args.modified:
        tasks = [v for v in get_changed_tasks()]
        log.warn('run changed tasks', tasks)
    else:
        tasks = [v for v in get_tasks()]
        log.warn('run all tasks', tasks)
        
    #get develop kpis of all tasks and write to develop_kpis
    if develop_evaluate == 'True':
        prepare_develop_kpis(tasks)

    for task in tasks:
        try:
            passed, eval_infos, kpis, kpi_values, kpi_types, detail_infos, develop_infos = evaluate(task)
            if mode != "baseline_test":
                log.warn('add evaluation %s result to mongodb' % task)
                kpi_objs = get_kpi_tasks(task)
                if (not args.modified) and (not specific_tasks):
                    pst.add_evaluation_record(commitid = paddle_commit,
                                              date = commit_time,
                                              task = task,
                                              passed = passed,
                                              infos = eval_infos,
                                              kpis = kpis,
                                              kpi_values = kpi_values,
                                              kpi_types = kpi_types,
                                              kpi_objs = kpi_objs,
                                              detail_infos = detail_infos,
                                              develop_infos = develop_infos)
            if not passed:
                all_passed = False
        except Exception as e:
            exception_task[task] = traceback.format_exc()
            all_passed = False

    return all_passed, exception_task


def prepare_develop_kpis(tasks):
    '''
    '''
    # get develop kpis from db
    develop_kpis = pst.get_kpis_from_db(tasks)
    # save kpi to file
    for task in tasks:
        try:
            if task not in develop_kpis:
                continue
            kpis = develop_kpis[task]
            kpis_keys = kpis['kpis-keys']
            kpis_values = json.loads(kpis['kpis-values'])
            assert len(kpis_keys)==len(kpis_values)
            for i in range(len(kpis_keys)):
                save_kpis(task, kpis_keys[i], kpis_values[i])
        except Exception as e:
            log.warn(e)
          

def save_kpis(task_name, kpi_name, kpi_value):
    '''
    '''
    develop_dir = "develop_kpis"
    task_dir = pjoin(_config.baseline_path, task_name)
    with PathRecover():
         os.chdir(task_dir)
         if not os.path.exists(develop_dir):
             os.makedirs(develop_dir)
         os.chdir(develop_dir)
         file_name = kpi_name + "_factor.txt"
         with open(file_name, 'w') as fout:
             for item in kpi_value:
                 fout.write(str(item) + '\n')
              

def evaluate(task_name):
    '''
    task_name: str
        name of a task directory.
    returns:
        passed: bool
            whether this task passes the evaluation.
        eval_infos: list of str
            human-readable evaluations result for all the kpis of this task.
        kpis: dict of (kpi_name, list_of_float)
    '''
    task_dir = pjoin(_config.baseline_path, task_name)
    log.warn('evaluating model', task_name)

    with PathRecover():
        try:
            cd @(task_dir)
            ./run.xsh
        except Exception as e:
            print(e)


        tracking_kpis = get_kpi_tasks(task_name)

        # evaluate all the kpis
        eval_infos = []
        detail_infos = []
        develop_infos = []
        kpis = []
        kpi_values = []
        kpi_types = []
        passed = True
        for kpi in tracking_kpis:
            suc = kpi.evaluate(task_dir)
            if (not suc) and kpi.actived:
                ''' Only if the kpi is actived, its evaluation result would affect the overall tasks's result. '''
                passed = False
                log.error("Task [%s] failed!" % task_name)
                log.error("details:", kpi.fail_info)
            kpis.append(kpi.name)
            kpi_values.append(kpi.cur_data)
            kpi_types.append(kpi.__class__.__name__)
            # if failed, still continue to evaluate the other kpis to get full statistics.
            eval_infos.append(kpi.fail_info if not suc else kpi.success_info)
            detail_infos.append(kpi.detail_info)
            develop_infos.append(kpi.develop_info)
            
        if develop_evaluate == 'False':
            develop_infos = []
        log.info("evaluation kpi info: %s %s %s" % (passed, eval_infos, kpis))
        return passed, eval_infos, kpis, kpi_values, kpi_types, detail_infos, develop_infos


def get_tasks():
    with PathRecover():
        cd @(_config.workspace)
        subdirs = $(ls @(_config.baseline_path)).split()
        if case_type:
            return filter(lambda x : x.startswith('%s_' % case_type), subdirs)
        else:
            return filter(lambda x : not (x.startswith('__') or x.startswith('model_')
                   or x.endswith('.md')), subdirs)


def display_fail_info(exception_task):
    paddle_commit = repo.get_commit(_config.paddle_path)
    infos = pst.db.finds(_config.table_name, {'commitid': paddle_commit, 'type': 'kpi' })
    log.error('Evaluate [%s] failed!' % paddle_commit)
    log.warn('The details:')
    detail_info = ''
    for info in infos:
        if not info['passed']:
            log.warn('task:', info['task'])
            detail_info += info['task'] + ' '
            log.warn('passed: ', info['passed'])
            log.warn('infos', '\n'.join(info['infos']))
            log.warn('kpis keys', info['kpis-keys'])
            log.warn('kpis values', info['kpis-values'])
    if exception_task:
        for task, info in exception_task.items():
            detail_info += task + ' '
            log.error("%s %s" %(task, info))
    with open("fail_models", 'w') as f:
        f.write(detail_info)


def display_success_info():
    paddle_commit = repo.get_commit(_config.paddle_path)
    log.warn('Evaluate [%s] successed!' % paddle_commit)


def try_start_mongod():
    out = $(ps ax | grep mongod).strip().split('\n')
    print('out', out)
    if len(out) < 1: # there are no mongod service
        log.warn('starting mongodb')
        mkdir -p /chunwei/ce_mongo.db
        mongod --dbpath /chunwei/ce_mongo.db &


def get_kpi_tasks(task_name):
    with PathRecover():
        cd @(_config.workspace)
        env = {}
        try:
            exec('from tasks.%s.continuous_evaluation import tracking_kpis'
                % task_name, env)
            log.info("import from continuous_evaluation suc.")
        except Exception as e: 
            exec('from tasks.%s._ce import tracking_kpis'
                % task_name, env)
        
        tracking_kpis = env['tracking_kpis']
        print(tracking_kpis)
        return tracking_kpis


def get_changed_tasks():
    tasks = []
    cd @(_config.baseline_path)
    out = $(git diff master | grep "diff --git")
    out = out.strip()
    for item in out.split('\n'):
        task = item.split()[3].split('/')[1]
        if task not in tasks:
            tasks.append(task)
    log.warn("changed tasks: %s" % tasks)
    return tasks

main()
