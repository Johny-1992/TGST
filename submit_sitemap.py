from googleapiclient.discovery import build
from google.oauth2 import service_account

SCOPES = ['https://www.googleapis.com/auth/webmasters']
SERVICE_ACCOUNT_FILE = 'credentials.json'

credentials = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES)

webmasters_service = build('searchconsole', 'v1', credentials=credentials)

site_url = 'https://tgst-jcvehdgl3-humangos-projects.vercel.app'
sitemap_url = f'{site_url}/sitemap.xml'

request = webmasters_service.sitemaps().submit(siteUrl=site_url, feedpath=sitemap_url)
request.execute()
print("✅ Sitemap soumis à Google Search Console")
