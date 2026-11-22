import os
import time
import httpx

class MediaWiki:
    """One importer process, explicit request budget, 1 request/sec, bounded retries."""
    def __init__(self,language='ru',budget=1000):
        if language not in ('ru','en'): raise ValueError('Unsupported language')
        user_agent=os.getenv('WIKIMEDIA_USER_AGENT')
        if not user_agent: raise ValueError('Set WIKIMEDIA_USER_AGENT=MARGO/0.2 (real contact URL or email)')
        self.client=httpx.Client(base_url=f'https://{language}.wikipedia.org',headers={'User-Agent':user_agent},timeout=20)
        self.remaining=budget;self.last=0
    def close(self): self.client.close()
    def query(self,**params):
        for attempt in range(4):
            if self.remaining<=0: raise RuntimeError('Wikimedia request budget exhausted')
            time.sleep(max(0,1-(time.monotonic()-self.last)))
            self.remaining-=1;self.last=time.monotonic()
            try:
                response=self.client.get('/w/api.php',params={'action':'query','format':'json','formatversion':2,'maxlag':5,**params})
                if response.status_code==429 or response.status_code>=500:
                    time.sleep(min(30,2**attempt));continue
                response.raise_for_status();data=response.json()
                if data.get('error',{}).get('code')=='maxlag': time.sleep(2**attempt);continue
                if 'error' in data: raise RuntimeError(str(data['error']))
                return data
            except (httpx.TimeoutException,httpx.NetworkError):
                if attempt==3: raise
                time.sleep(2**attempt)
        raise RuntimeError('Wikimedia retries exhausted')
    def category(self,title):
        pages=self.query(titles=title,redirects=1)['query']['pages']
        return next((p for p in pages if 'missing' not in p and p.get('ns')==14),None)
    def members(self,title,kind='subcat',limit=81):
        result=[];continuation={}
        while len(result)<limit:
            data=self.query(list='categorymembers',cmtitle=title,cmtype=kind,cmlimit=min(500,limit-len(result)),**continuation)
            result.extend(data['query']['categorymembers'])
            if 'continue' not in data: break
            continuation=data['continue']
        return result[:limit]
    def iter_pages(self, title):
        """Lazy continuation avoids repeatedly stopping at the first 500 pages."""
        continuation = {}
        while True:
            data = self.query(list='categorymembers', cmtitle=title, cmtype='page',
                              cmlimit=100, **continuation)
            yield from data['query']['categorymembers']
            if 'continue' not in data:
                return
            continuation = data['continue']
    def article(self,page_id):
        data=self.query(pageids=page_id,prop='extracts|categories|info',exintro=1,explaintext=1,clshow='!hidden',cllimit=500,inprop='url')
        page=data['query']['pages'][0]
        # Category truncation is unsafe for classification; quarantine these pages.
        page['categories_complete']='continue' not in data
        return page
    def articles(self,titles):
        """Resolve up to 20 editorial targets, including redirects and disambiguations."""
        if not 1<=len(titles)<=20: raise ValueError('Batch must contain 1..20 titles')
        return self.query(titles='|'.join(titles),redirects=1,prop='extracts|info|pageprops',exintro=1,explaintext=1,inprop='url',ppprop='disambiguation')
