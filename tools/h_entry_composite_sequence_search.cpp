// HC-R bounded chronological first-release search, never strategy simulation.
#include <algorithm>
#include <fstream>
#include <iostream>
#include <set>
#include <map>
#include <vector>
#include <iomanip>
#include <cstdint>
using namespace std;
struct Node{vector<int>a;double worst,mean;};
int A,N; vector<int> ids,parents,groups,F,den(4); vector<uint32_t> stocks; vector<uint8_t> H;vector<double> G;long long evaluationCount=0,passed=0;
template<class T> void load(ifstream&f,vector<T>&v,size_t n){v.resize(n);f.read((char*)v.data(),n*sizeof(T));if(!f)throw runtime_error("input truncated");}
bool better(const Node&a,const Node&b){if(a.worst!=b.worst)return a.worst>b.worst;if(a.mean!=b.mean)return a.mean>b.mean;return a.a<b.a;}
void consider(vector<int> atoms, vector<Node>&out){
 ++evaluationCount;if(evaluationCount>2000000)throw runtime_error("budget");double sums[4]={};int hits[4]={};uint32_t masks[4]={};
 for(int k=0;k<N;k++){int first=INT32_MAX,source=-1;bool hit=true;
  for(int a:atoms){int ix=a*N+k;if(!H[ix]){hit=false;break;}if(F[ix]<first){first=F[ix];source=ix;}}
  if(hit){int g=groups[k];sums[g]+=G[source];hits[g]++;masks[g]|=stocks[k];}
 }
 double worst=1e9,mean=0;
 for(int g=0;g<4;g++){if(hits[g]<10||__builtin_popcount(masks[g])<5||sums[g]<=0)return;double v=sums[g]/den[g];worst=min(worst,v);mean+=v/4;}
 passed++;out.push_back({atoms,worst,mean});if(out.size()>20000){sort(out.begin(),out.end(),better);out.resize(10000);}
}
vector<Node> beam(vector<Node>v){sort(v.begin(),v.end(),better);vector<Node>b;map<vector<int>,int> fam;for(auto &x:v){vector<int>p;for(int a:x.a)p.push_back(parents[a]);sort(p.begin(),p.end());if(fam[p]>=2)continue;fam[p]++;b.push_back(x);if(b.size()==200)break;}return b;}
int main(int argc,char**argv){if(argc!=3)return 2;ifstream f(argv[1],ios::binary);f.read((char*)&A,4);f.read((char*)&N,4);load(f,ids,A);load(f,parents,A);load(f,groups,N);load(f,stocks,N);load(f,H,A*N);load(f,F,A*N);load(f,G,A*N);for(int g:groups)den[g]++;
 vector<Node>cur,all;
 for(int i=0;i<A;i++){for(int j=i+1;j<A;j++)if(parents[i]!=parents[j])consider({i,j},cur);if(i%200==0)cerr<<"pairs "<<i<<" evaluations "<<evaluationCount<<" passing "<<passed<<endl;}
 cur=beam(cur);all.insert(all.end(),cur.begin(),cur.end());
 for(int depth=3;depth<=4;depth++){vector<Node>next;set<vector<int>>seen;for(auto&r:cur)for(int a=0;a<A;a++){bool dup=false;for(int b:r.a)if(parents[a]==parents[b])dup=true;if(dup)continue;auto v=r.a;v.push_back(a);sort(v.begin(),v.end());if(seen.insert(v).second)consider(v,next);}cur=beam(next);all.insert(all.end(),cur.begin(),cur.end());cerr<<"depth "<<depth<<" evaluations "<<evaluationCount<<" passing "<<passed<<" beam "<<cur.size()<<endl;}
 sort(all.begin(),all.end(),better);ofstream o(argv[2]);o<<setprecision(17)<<"{\"evaluations\":"<<evaluationCount<<",\"passing\":"<<passed<<",\"nodes\":[";bool comma=false;for(auto&r:all){if(comma)o<<",";comma=true;o<<"{\"atoms\":[";for(int i=0;i<r.a.size();i++){if(i)o<<",";o<<ids[r.a[i]];}o<<"],\"worst\":"<<r.worst<<",\"mean\":"<<r.mean<<"}";}o<<"]}\n";
}
