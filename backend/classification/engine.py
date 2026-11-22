from collections import deque

VERSION='graph-v1'
SERVICE_MARKERS=('википедия','статьи','шаблон','служебн','wikipedia','maintenance','articles needing','pages with','tracking')

def is_editorial(title):
    return any(marker in title.lower() for marker in SERVICE_MARKERS)

def walk(seed, children, max_depth=2, max_categories=150, max_branch=80):
    """Bounded BFS: nearest path wins; no recursion or cycle amplification."""
    if not 0<=max_depth<=2: raise ValueError('Maximum depth is two')
    queue=deque([(seed,0)]);visited={}
    while queue and len(visited)<max_categories:
        title,distance=queue.popleft()
        if title in visited or is_editorial(title): continue
        visited[title]=distance
        if distance==max_depth: continue
        branch=list(children(title))
        if len(branch)>max_branch: continue
        queue.extend((child,distance+1) for child in branch if child not in visited)
    return visited

def classify(categories,mappings):
    result={}
    for category in categories:
        for topic,distance in mappings.get(category,[]):
            if 0<=distance<=2: result[topic]=max(result.get(topic,0),.7**distance)
    return result

def evaluate(labeled,predicted):
    topics=set(t for labels in labeled.values() for t in labels)|set(t for labels in predicted.values() for t in labels)
    report={}
    for topic in sorted(topics):
        tp=sum(topic in labeled.get(id,[]) and topic in predicted.get(id,[]) for id in labeled)
        fp=sum(topic not in labeled.get(id,[]) and topic in predicted.get(id,[]) for id in labeled)
        fn=sum(topic in labeled.get(id,[]) and topic not in predicted.get(id,[]) for id in labeled)
        precision=tp/(tp+fp) if tp+fp else 0;recall=tp/(tp+fn) if tp+fn else 0
        report[topic]={'precision':precision,'recall':recall,'f1':2*precision*recall/(precision+recall) if precision+recall else 0}
    return {'topics':report,'unclassified_fraction':sum(not predicted.get(id) for id in labeled)/len(labeled) if labeled else 0}
