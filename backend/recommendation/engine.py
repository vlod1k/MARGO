from collections import Counter

FEEDBACK = {'liked':1, 'uninterested':-1, 'known':0, 'difficult':0}

def interest_weights(selected, interactions, articles, topics):
    weights = {t: .8 if t in selected else .2 for t in topics}
    for interaction in interactions:
        article = articles.get(interaction.article_id)
        if article:
            for topic, value in article.topics.items():
                weights[topic] = weights.get(topic,.2) + .05 * FEEDBACK.get(interaction.feedback,0) * value
    return {t:max(0.,min(1.,value)) for t,value in weights.items()}

def rank(candidates, weights, recent_topics, all_topics, discovery=False):
    counts = Counter(all_topics)
    result=[]
    for article in candidates:
        mass=sum(article.topics.values())
        if not mass: continue
        relevance=sum(weights.get(t,.2)*w for t,w in article.topics.items())/mass
        diversity=sum(w for t,w in article.topics.items() if t not in recent_topics)/mass
        novelty=sum(w/(1+counts[t]) for t,w in article.topics.items())/mass
        score=.65*relevance+.20*diversity+.15*novelty
        if discovery:
            # A discovery day prioritizes unfamiliar, low-interest directions.
            score=.20*relevance+.30*diversity+.50*sum(w*(1-weights.get(t,.2))/(1+counts[t]) for t,w in article.topics.items())/mass
        result.append((score,article))
    return sorted(result,key=lambda pair:(-pair[0],pair[1].id))
