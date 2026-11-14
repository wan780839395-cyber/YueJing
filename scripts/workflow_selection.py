"""Inventory-driven display only; declarations/plans never imply native passes."""
import argparse
import json
import os
from pathlib import Path
import task3_test_inventory as inventory


def summarize(groups, root=inventory.ROOT):
    inventory.validate_source(root)
    if not groups or len(groups) != len(set(groups)) or any(g not in inventory.COUNTS for g in groups):
        raise ValueError('Explicit unique inventory groups required')
    return dict(kind='SELECTION_ONLY_NOT_EXECUTION',
                groups={g:dict(declarations=inventory.COUNTS[g], planned_executions=inventory.EXECUTION_COUNTS[g]) for g in groups},
                selected_declarations=sum(inventory.COUNTS[g] for g in groups),
                planned_executions=sum(inventory.EXECUTION_COUNTS[g] for g in groups),
                native_executions=None, passed=None)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--full',action='store_true')
    ap.add_argument('--group',action='append')
    args=ap.parse_args()
    if args.full == bool(args.group):raise ValueError('Select full OR exact groups')
    result=summarize(list(inventory.COUNTS) if args.full else args.group)
    text=json.dumps(result,indent=2)
    print(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a',encoding='utf-8') as out:
            out.write('\n## Selected inventory (not executed)\n```json\n'+text+'\n```\n')

if __name__=='__main__':main()
