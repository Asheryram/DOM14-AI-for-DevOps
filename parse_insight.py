import json
import sys
from datetime import datetime


def human_range(r):
    s = r.get('StartTime')
    e = r.get('EndTime')
    return f"{s} -> {e}"


def main():
    path = 'insight_export.json'
    if len(sys.argv) > 1:
        path = sys.argv[1]
    with open(path) as f:
        data = json.load(f)

    insights = data.get('Insights', []) if isinstance(data, dict) else data
    for it in insights:
        print('InsightId:', it.get('InsightId'))
        print('Name:', it.get('Name'))
        print('Severity:', it.get('Severity'))
        print('Status:', it.get('Status'))
        atr = it.get('AnomalyTimeRange', {})
        print('AnomalyTimeRange:', human_range(atr))
        correlated = it.get('TopAnomaly', {})
        print('Top correlated metric:', correlated.get('MetricName'), 'deviation:', correlated.get('Deviation'))
        print('---')


if __name__ == '__main__':
    main()
