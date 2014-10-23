/*
Read the file that has traces of all nodes in the system.
Seperate the traces based on the node from which it was sent.
The seperate traces are written to outfile_nodenumber
*/



#include <fstream>
#include <iostream>
#include <vector>
#include <string>
#include <cstdlib>
#include <sstream>

using namespace std;

void Tokenize(const std::string& str, std::vector<std::string>& tokens,const std::string& delimiters = " ")
{
    // Skip delimiters at beginning.
    int lastPos = str.find_first_not_of(delimiters, 0);
    // Find first "non-delimiter".
    int pos     = str.find_first_of(delimiters, lastPos);

    while (std::string::npos != pos || std::string::npos != lastPos)
    {
        // Found a token, add it to the vector.
        tokens.push_back(str.substr(lastPos, pos - lastPos));
        // Skip delimiters.  Note the "not_of"
        lastPos = str.find_first_not_of(delimiters, pos);
        // Find next "non-delimiter"
        pos = str.find_first_of(delimiters, lastPos);
    }
}


int main( int argc, char **argv )
{
  int i;
  int num_nodes;
  char *filename;
  std::vector<std::string> tokens;

  filename = argv[1];

  ifstream infile;

  infile.open(filename);

  if(argc > 2) {
    num_nodes = atoi(argv[2]);
  } else {
    num_nodes = 64;
  }

  /*
  ofstream *outfiles;
  outfiles = new ofstream [num_nodes];

  ostringstream outfilename;
  
  for(i=0; i<num_nodes; i++) {
    outfilename << "outfile_" << i;
    outfiles[i].open(outfilename.str());
    outfilename.seekp(0, ios::beg);
  }
  */
  ofstream outfile;
  ostringstream outfilename;
  
  std::string lineread;
  //int k = 0;
  while(getline(infile, lineread)){
    //printf("Line no. %d\n", k);
    //k++;
    Tokenize(lineread, tokens);
    if(atoi(tokens[1].data()) < 10)
      outfilename << "outfile_0" << atoi(tokens[1].data());
    else
      outfilename << "outfile_" << atoi(tokens[1].data());

    outfile.open((outfilename.str()).data() , ios::out | ios::app);

    outfile << lineread <<"\n";
    //outfile.write(lineread.data(), lineread.length());
    //cout << outfilename.str() << "\n";

    tokens.erase (tokens.begin(), tokens.end());
    outfilename.seekp(0, ios::beg);
    outfile.close();
  }
  
  /*
  for(i=0; i<num_nodes; i++) {
    outfiles[i].close();
  }
  */

  infile.close();

  return 0;
}


